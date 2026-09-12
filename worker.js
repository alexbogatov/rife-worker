import os from 'os';
import { readFileSync, createReadStream, existsSync } from 'fs';
import { mkdir, writeFile, unlink, rename } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

// Suppress Node deprecation/SDK alerts
process.removeAllListeners('warning');

const WORKER_SUFFIX = process.env.WORKER_SUFFIX || 'worker_1';
const COMFY_PORT = parseInt(process.env.COMFY_PORT, 10) || 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_FILE = process.env.WORKFLOW_FILE || 'rife_v4.26_heavy.json';
const WORKFLOW_PATH = join(process.cwd(), WORKFLOW_FILE);

const WORKER_NUM = (WORKER_SUFFIX.match(/\d+/) ? WORKER_SUFFIX.match(/\d+/)[0] : '1').padStart(3, '0');
const TAG = `[ ${WORKER_NUM} ]`;

const BASE_COMFY_DIR = existsSync('/app/ComfyUI') ? '/app/ComfyUI' : join(process.cwd(), 'ComfyUI');
const INPUT_DIR = join(BASE_COMFY_DIR, 'input');
const OUTPUT_DIR = join(BASE_COMFY_DIR, 'output');

const MACHINE_ID = os.hostname();
const UNIQUE_WORKER_ID = `${MACHINE_ID}-${WORKER_SUFFIX}`;
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;
const WORKER_SESSION_ID = process.env.WORKER_SESSION_ID || null;

const active_uploads = new Set();
const STATS_FILE = `/tmp/worker_stats_${WORKER_SUFFIX}.json`;
let jobs_processed = 0;
let total_generation_time_sec = 0;

const API_BASE_URL = process.env.API_BASE_URL || 'https://api.runltx.com';
const JOB_TYPE = process.env.JOB_TYPE || 'interpolate';
const MODEL_TYPE = process.env.MODEL || process.env.MODEL_TYPE || 'interpolate-video';
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10) || 1;
const MAX_EMPTY_POLLS = parseInt(process.env.MAX_EMPTY_POLLS, 10) || 3;

const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID || '',
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY || '',
  },
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
  } catch (_) {}
};

const poll_for_job = async () => {
  try {
    const res = await fetch(`${API_BASE_URL}/v1/worker/get`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        slot: WORKER_SUFFIX,
        job_type: JOB_TYPE,
        model: MODEL_TYPE,
        models: MODEL_TYPE
      })
    });
    if (!res.ok) return null;
    return await res.json();
  } catch (_) {
    return null;
  }
};

const complete_job = async (job_id, output_url, generation_time_sec) => {
  try {
    await fetch(`${API_BASE_URL}/v1/worker/complete`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        output_url,
        generation_time_sec,
      }),
    });
    jobs_processed += 1;
    total_generation_time_sec += generation_time_sec;
    await sync_stats_to_disk();
  } catch (_) {}
};

const fail_job = async (job_id, error_message) => {
  try {
    await fetch(`${API_BASE_URL}/v1/worker/fail`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        error_message: String(error_message)
      }),
    });
  } catch (_) {}
};

const wait_for_comfy_ready = async () => {
  while (true) {
    try {
      const res = await fetch(`${COMFY_HOST}/history`);
      if (res.ok) break;
    } catch (_) {}
    await sleep(250);
  }
};

const mutate_workflow = (workflow, { input_filename, multiplier = 4 }) => {
  if (workflow['4']?.inputs) workflow['4'].inputs.file = input_filename;
  if (workflow['16:9']?.inputs) workflow['16:9'].inputs.value = parseInt(multiplier, 10) || 4;
  if (workflow['7']?.inputs) workflow['7'].inputs.filename_prefix = `video/${WORKER_SUFFIX}_ComfyUI`;
  return workflow;
};

const execute_workflow = async (workflow) => {
  const response = await fetch(`${COMFY_HOST}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow }),
  });
  const { prompt_id } = await response.json();
  const start_time = Date.now();

  while (true) {
    await sleep(250);
    const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`);
    if (history_res.ok) {
      const history_data = await history_res.json();
      const job_history = history_data[prompt_id];
      if (job_history) {
        const duration = (Date.now() - start_time) / 1000;
        const outputs = job_history.outputs || {};
        for (const nodeId in outputs) {
          const vids = outputs[nodeId].videos || outputs[nodeId].gifs || outputs[nodeId].images;
          if (vids && vids.length > 0) {
            const vid = vids[0];
            const sub = vid.subfolder ? `${vid.subfolder}/` : '';
            return { output_path: join(OUTPUT_DIR, `${sub}${vid.filename}`), duration };
          }
        }
        throw new Error('No video output found');
      }
    }
  }
};

const download_video = async (url, filename) => {
  const res = await fetch(url);
  const buffer = await res.arrayBuffer();
  await mkdir(INPUT_DIR, { recursive: true });
  const target_path = join(INPUT_DIR, filename);
  await writeFile(target_path, Buffer.from(buffer));
  return target_path;
};

const upload_to_r2 = async (file_path, job_id) => {
  const ext = file_path.endsWith('.webm') ? 'webm' : 'mp4';
  const key = `interpolations/${job_id}.${ext}`;
  await s3_client.send(new PutObjectCommand({
    Bucket: process.env.R2_BUCKET_NAME,
    Key: key,
    Body: createReadStream(file_path),
    ContentType: ext === 'webm' ? 'video/webm' : 'video/mp4',
  }));
  return `${process.env.R2_CDN_URL}/${key}`;
};

const upload_and_complete_async = async (job_id, isolated_path, input_paths, duration) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id);
    await complete_job(job_id, r2_url, duration);
    console.log(`\x1b[32m${TAG} ✔ Job [${job_id}] finished in ${duration.toFixed(1)}s\x1b[0m`);
  } catch (err) {
    await fail_job(job_id, err.message);
  } finally {
    try { await unlink(isolated_path); } catch (_) {}
    for (const p of input_paths) {
      try { await unlink(p); } catch (_) {}
    }
  }
};

const prepare_job = async (job_data) => {
  const { job_id } = job_data;
  const input = job_data.input || {};
  const video_url = input.video_url || job_data.video_url;
  const multiplier = input.multiplier || job_data.multiplier || 4;

  const ext = video_url.includes('.webm') ? 'webm' : 'mp4';
  const input_filename = `${WORKER_SUFFIX}_${job_id}_input.${ext}`;
  const input_path = await download_video(video_url, input_filename);
  const workflow = mutate_workflow(JSON.parse(readFileSync(WORKFLOW_PATH, 'utf-8')), { input_filename, multiplier });

  return { job_id, workflow, downloaded_paths: [input_path] };
};

const prefetch_next_job = async () => {
  try {
    const result = await poll_for_job();
    if (!result?.success || !result?.data) return null;
    return await prepare_job(result.data);
  } catch (_) {
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
        current_job = await prefetch_next_job();
      }

      if (!current_job) {
        empty_poll_count++;
        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          if (active_uploads.size > 0) await Promise.allSettled(Array.from(active_uploads));
          await sync_stats_to_disk();
          process.exit(0);
        }
        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      console.log(`${TAG} Got job ${current_job.job_id}`);

      // 1. Concurrently prefetch next video during GPU generation
      prefetch_promise = prefetch_next_job();

      try {
        const { output_path: generated_file, duration } = await execute_workflow(current_job.workflow);

        const ext = generated_file.endsWith('.webm') ? 'webm' : 'mp4';
        const isolated_path = join(OUTPUT_DIR, `uploading_${WORKER_SUFFIX}_${current_job.job_id}.${ext}`);
        await rename(generated_file, isolated_path);

        // 2. Concurrently upload to R2 while loop picks up the next job immediately
        const upload_task = upload_and_complete_async(
          current_job.job_id,
          isolated_path,
          current_job.downloaded_paths,
          duration
        );
        active_uploads.add(upload_task);
        upload_task.finally(() => active_uploads.delete(upload_task));

      } catch (render_err) {
        for (const p of current_job.downloaded_paths) {
          try { await unlink(p); } catch (_) {}
        }
        await fail_job(current_job.job_id, render_err.message);
      }

      current_job = null;
    } catch (_) {
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

worker_loop();