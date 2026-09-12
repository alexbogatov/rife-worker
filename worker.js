import os from 'os';
import { readFileSync, createReadStream, existsSync, statSync } from 'fs';
import { mkdir, writeFile, unlink, rename } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

process.removeAllListeners('warning');

// ==============================================================================
// Strict Environment Validation (No Fallbacks)
// ==============================================================================
const REQUIRED_ENV_VARS = [
  'WORKER_SUFFIX',
  'COMFY_PORT',
  'WORKFLOW_FILE',
  'API_BASE_URL',
  'WORKER_API_SECRET',
  'WORKER_SESSION_ID',
  'JOB_TYPE',
  'MODEL',
  'POLL_INTERVAL_SECONDS',
  'MAX_EMPTY_POLLS',
  'R2_ACCOUNT_ID',
  'R2_ACCESS_KEY_ID',
  'R2_SECRET_ACCESS_KEY',
  'R2_BUCKET_NAME',
  'R2_CDN_URL'
];

const missing_vars = REQUIRED_ENV_VARS.filter((key) => {
  const val = process.env[key];
  return val === undefined || val === null || val.trim() === '';
});

if (missing_vars.length > 0) {
  console.error(`\x1b[31m[FATAL] Missing required environment variable(s):\n  - ${missing_vars.join('\n  - ')}\x1b[0m`);
  process.exit(1);
}

const WORKER_SUFFIX = process.env.WORKER_SUFFIX;
const COMFY_PORT = parseInt(process.env.COMFY_PORT, 10);
if (isNaN(COMFY_PORT)) {
  console.error(`\x1b[31m[FATAL] COMFY_PORT must be an integer, got: "${process.env.COMFY_PORT}"\x1b[0m`);
  process.exit(1);
}

const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_FILE = process.env.WORKFLOW_FILE;
const WORKFLOW_PATH = join(process.cwd(), WORKFLOW_FILE);

if (!existsSync(WORKFLOW_PATH)) {
  console.error(`\x1b[31m[FATAL] Workflow JSON file not found at: ${WORKFLOW_PATH}\x1b[0m`);
  process.exit(1);
}

const WORKER_NUM = (WORKER_SUFFIX.match(/\d+/) ? WORKER_SUFFIX.match(/\d+/)[0] : '1').padStart(3, '0');
const TAG = `[ ${WORKER_NUM} ]`;

const BASE_COMFY_DIR = existsSync('/app/ComfyUI') ? '/app/ComfyUI' : join(process.cwd(), 'ComfyUI');
const INPUT_DIR = join(BASE_COMFY_DIR, 'input');
const OUTPUT_DIR = join(BASE_COMFY_DIR, 'output');

const MACHINE_ID = os.hostname();
const UNIQUE_WORKER_ID = `${MACHINE_ID}-${WORKER_SUFFIX}`;
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;
const WORKER_SESSION_ID = process.env.WORKER_SESSION_ID;

const API_BASE_URL = process.env.API_BASE_URL;
const JOB_TYPE = process.env.JOB_TYPE;
const MODEL_TYPE = process.env.MODEL;
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10);
const MAX_EMPTY_POLLS = parseInt(process.env.MAX_EMPTY_POLLS, 10);

const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

const active_uploads = new Set();
const STATS_FILE = `/tmp/worker_stats_${WORKER_SUFFIX}.json`;
let jobs_processed = 0;
let total_generation_time_sec = 0;

// S3 Client with connection/socket timeouts to prevent hanging on dropped connections
const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
  },
  requestHandler: {
    requestTimeout: 60000,
    connectionTimeout: 10000,
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const get_api_headers = () => ({
  'worker-auth': WORKER_API_SECRET,
  'x-machine-id': MACHINE_ID,
  'x-worker-id': UNIQUE_WORKER_ID,
  'content-type': 'application/json'
});

const sync_stats_to_disk = async () => {
  try {
    await writeFile(STATS_FILE, JSON.stringify({
      worker: UNIQUE_WORKER_ID,
      jobs_processed,
      total_generation_time_sec: Math.round(total_generation_time_sec * 100) / 100
    }));
  } catch (err) {
    console.error(`\x1b[31m${TAG} Failed to write stats to disk: ${err.message}\x1b[0m`);
  }
};

const poll_for_job = async () => {
  const payload = {
    session_id: WORKER_SESSION_ID,
    worker_id: UNIQUE_WORKER_ID,
    slot: WORKER_SUFFIX,
    job_type: JOB_TYPE,
    model: MODEL_TYPE,
    models: MODEL_TYPE
  };

  try {
    const res = await fetch(`${API_BASE_URL}/v1/worker/get`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(15000)
    });

    const bodyText = await res.text();

    if (!res.ok) {
      console.error(`\x1b[31m${TAG} API Poll HTTP Error ${res.status} ${res.statusText}: ${bodyText}\x1b[0m`);
      return null;
    }

    let json;
    try {
      json = JSON.parse(bodyText);
    } catch (parseErr) {
      console.error(`\x1b[31m${TAG} Failed to parse API Poll JSON response: ${bodyText}\x1b[0m`);
      return null;
    }

    if (!json.success || !json.data) {
      return null;
    }

    return await prepare_job(json.data);
  } catch (err) {
    console.error(`\x1b[31m${TAG} API Poll Network Error: ${err.message}\x1b[0m`);
    return null;
  }
};

const complete_job = async (job_id, output_url, generation_time_sec) => {
  try {
    console.log(`${TAG} Completing job [${job_id}] via API...`);
    const res = await fetch(`${API_BASE_URL}/v1/worker/complete`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        output_url,
        generation_time_sec,
      }),
      signal: AbortSignal.timeout(15000)
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error(`\x1b[31m${TAG} Complete API rejected HTTP ${res.status}: ${errText}\x1b[0m`);
    } else {
      jobs_processed += 1;
      total_generation_time_sec += generation_time_sec;
      await sync_stats_to_disk();
    }
  } catch (err) {
    console.error(`\x1b[31m${TAG} Complete API Network Error [${job_id}]: ${err.message}\x1b[0m`);
  }
};

const fail_job = async (job_id, error_message) => {
  try {
    const res = await fetch(`${API_BASE_URL}/v1/worker/fail`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        error_message: String(error_message)
      }),
      signal: AbortSignal.timeout(15000)
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error(`\x1b[31m${TAG} Fail API call rejected HTTP ${res.status}: ${errText}\x1b[0m`);
    }
  } catch (err) {
    console.error(`\x1b[31m${TAG} Fail API Network Error [${job_id}]: ${err.message}\x1b[0m`);
  }
};

const wait_for_comfy_ready = async () => {
  while (true) {
    try {
      const res = await fetch(`${COMFY_HOST}/history`, { signal: AbortSignal.timeout(3000) });
      if (res.ok) break;
    } catch (_) {}
    await sleep(250);
  }
};

const free_comfy_vram = async () => {
  try {
    await fetch(`${COMFY_HOST}/free`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ unload_models: false, free_memory: true }),
      signal: AbortSignal.timeout(5000)
    });
  } catch (err) {
    console.warn(`${TAG} ComfyUI VRAM flush notice: ${err.message}`);
  }
};

const mutate_workflow = (workflow, { input_filename, multiplier }) => {
  if (workflow['4']?.inputs) workflow['4'].inputs.file = input_filename;
  if (workflow['16:9']?.inputs) workflow['16:9'].inputs.value = parseInt(multiplier, 10);
  if (workflow['7']?.inputs) workflow['7'].inputs.filename_prefix = `video/${WORKER_SUFFIX}_ComfyUI`;
  return workflow;
};

const execute_workflow = async (workflow) => {
  const response = await fetch(`${COMFY_HOST}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow }),
    signal: AbortSignal.timeout(15000)
  });

  const resJson = await response.json();

  if (!response.ok || resJson.error || !resJson.prompt_id) {
    const errorDetails = JSON.stringify(resJson.node_errors || resJson.error || resJson);
    throw new Error(`ComfyUI Prompt Rejected: ${errorDetails}`);
  }

  const { prompt_id } = resJson;
  const start_time = Date.now();

  while (true) {
    await sleep(250);
    try {
      const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`, { signal: AbortSignal.timeout(5000) });
      if (history_res.ok) {
        const history_data = await history_res.json();
        const job_history = history_data[prompt_id];
        if (job_history) {
          if (job_history.status?.status_str === 'error') {
            throw new Error(`ComfyUI Execution Error: ${JSON.stringify(job_history.status)}`);
          }

          const duration = (Date.now() - start_time) / 1000;
          const outputs = job_history.outputs || {};

          const saveNodeOutput = outputs['7'];
          const mediaList = saveNodeOutput?.gifs || saveNodeOutput?.videos || saveNodeOutput?.images;

          if (mediaList && mediaList.length > 0) {
            const item = mediaList[0];
            const sub = item.subfolder ? `${item.subfolder}/` : '';
            return { output_path: join(OUTPUT_DIR, `${sub}${item.filename}`), duration };
          }

          for (const nodeId of Object.keys(outputs)) {
            for (const key of ['gifs', 'videos', 'images']) {
              const list = outputs[nodeId][key];
              if (Array.isArray(list)) {
                const outItem = list.find((v) => v.type === 'output');
                if (outItem) {
                  const sub = outItem.subfolder ? `${outItem.subfolder}/` : '';
                  return { output_path: join(OUTPUT_DIR, `${sub}${outItem.filename}`), duration };
                }
              }
            }
          }

          throw new Error('No valid output video found in completed workflow history');
        }
      }
    } catch (pollErr) {
      if (pollErr.message.includes('ComfyUI Execution Error') || pollErr.message.includes('No valid output video')) {
        throw pollErr;
      }
    }
  }
};

const download_video = async (url, filename) => {
  const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!res.ok) throw new Error(`HTTP ${res.status} downloading ${url}`);

  const buffer = await res.arrayBuffer();
  if (buffer.byteLength < 1024) {
    throw new Error(`Downloaded video is empty or corrupt (${buffer.byteLength} bytes)`);
  }

  await mkdir(INPUT_DIR, { recursive: true });

  const temp_path = join(INPUT_DIR, `temp_${Date.now()}_${filename}`);
  const target_path = join(INPUT_DIR, filename);

  await writeFile(temp_path, Buffer.from(buffer));
  await rename(temp_path, target_path);

  return target_path;
};

const upload_to_r2 = async (file_path, job_id) => {
  if (!existsSync(file_path)) {
    throw new Error(`File not found for R2 upload at path: ${file_path}`);
  }

  const ext = file_path.endsWith('.webm') ? 'webm' : 'mp4';
  const key = `interpolations/${job_id}.${ext}`;
  const contentType = ext === 'webm' ? 'video/webm' : 'video/mp4';
  const file_size = statSync(file_path).size;

  console.log(`${TAG} [upload] Sending ${file_path} (${(file_size / 1024 / 1024).toFixed(2)} MB) to R2 key: ${key}...`);

  await s3_client.send(new PutObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key,
    Body: createReadStream(file_path),
    ContentLength: file_size,
    ContentType: contentType,
  }));

  console.log(`${TAG} [upload] Finished uploading ${key} to R2.`);
  return `${R2_CDN_URL}/${key}`;
};

const upload_and_complete_async = async (job_id, isolated_path, duration) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id);
    await complete_job(job_id, r2_url, duration);
    console.log(`\x1b[32m${TAG} ✔ Job [${job_id}] finished in ${duration.toFixed(1)}s\x1b[0m`);
  } catch (err) {
    console.error(`\x1b[31m${TAG} ✖ Upload/Complete Failed [${job_id}]: ${err.message}\x1b[0m`);
    await fail_job(job_id, err.message);
  } finally {
    try { await unlink(isolated_path); } catch (_) {}
  }
};

const prepare_job = async (job_data) => {
  const { job_id } = job_data;
  const input = job_data.input || {};
  const video_url = input.video_url || job_data.video_url;
  const multiplier = input.multiplier || job_data.multiplier || 4;

  if (!video_url) {
    throw new Error(`Job [${job_id}] payload is missing a valid video_url`);
  }

  const ext = video_url.includes('.webm') ? 'webm' : 'mp4';
  const input_filename = `${WORKER_SUFFIX}_${job_id}_input.${ext}`;
  const input_path = await download_video(video_url, input_filename);
  const workflow = mutate_workflow(JSON.parse(readFileSync(WORKFLOW_PATH, 'utf-8')), { input_filename, multiplier });

  return { job_id, workflow, downloaded_paths: [input_path] };
};

const prefetch_next_job = async () => {
  try {
    return await poll_for_job();
  } catch (err) {
    console.error(`\x1b[31m${TAG} Prefetch error: ${err.message}\x1b[0m`);
    return null;
  }
};

const worker_loop = async () => {
  await mkdir(INPUT_DIR, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });
  await sync_stats_to_disk();
  await wait_for_comfy_ready();

  let current_job = null;
  let prefetch_promise = null;
  let empty_poll_count = 0;

  while (true) {
    try {
      if (prefetch_promise) {
        current_job = await prefetch_promise;
        prefetch_promise = null;
      }

      if (!current_job) {
        current_job = await poll_for_job();
      }

      if (!current_job) {
        empty_poll_count++;

        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          console.warn(`\x1b[33m${TAG} Reached MAX_EMPTY_POLLS (${MAX_EMPTY_POLLS}). Shutting down worker...\x1b[0m`);
          if (active_uploads.size > 0) {
            console.log(`${TAG} Awaiting ${active_uploads.size} remaining background upload(s)...`);
            await Promise.allSettled(Array.from(active_uploads));
          }
          await sync_stats_to_disk();
          process.exit(0);
        }

        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      console.log(`${TAG} Got job ${current_job.job_id}`);

      prefetch_promise = prefetch_next_job();

      try {
        const { output_path: generated_file, duration } = await execute_workflow(current_job.workflow);

        for (const p of current_job.downloaded_paths) {
          try { await unlink(p); } catch (_) {}
        }

        const ext = generated_file.endsWith('.webm') ? 'webm' : 'mp4';
        const isolated_path = join(OUTPUT_DIR, `uploading_${WORKER_SUFFIX}_${current_job.job_id}.${ext}`);
        await rename(generated_file, isolated_path);

        const upload_task = upload_and_complete_async(
          current_job.job_id,
          isolated_path,
          duration
        );
        active_uploads.add(upload_task);
        upload_task.finally(() => active_uploads.delete(upload_task));

      } catch (render_err) {
        console.error(`\x1b[31m${TAG} ✖ Job Execution Failed [${current_job.job_id}]: ${render_err.message}\x1b[0m`);
        for (const p of current_job.downloaded_paths) {
          try { await unlink(p); } catch (_) {}
        }
        await fail_job(current_job.job_id, render_err.message);
      } finally {
        await free_comfy_vram();
      }

      current_job = null;
    } catch (loop_err) {
      console.error(`\x1b[31m${TAG} Critical Uncaught Loop Error: ${loop_err.message}\x1b[0m`);
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

worker_loop();