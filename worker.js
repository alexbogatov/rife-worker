import os from 'os';
import { readFileSync, createReadStream, existsSync } from 'fs';
import { mkdir, writeFile, unlink, rename } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

// ============================================
// CONSTANTS & IDENTITY
// ============================================
const WORKER_SUFFIX = process.env.WORKER_SUFFIX || 'worker_1';
const COMFY_PORT = parseInt(process.env.COMFY_PORT, 10) || 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_FILE = process.env.WORKFLOW_FILE || 'rife_v4.26_heavy.json';
const WORKFLOW_PATH = join(process.cwd(), WORKFLOW_FILE);

// Tag format: [ 001 ], [ 002 ], ..., [ 012 ]
const WORKER_NUM = (WORKER_SUFFIX.match(/\d+/) ? WORKER_SUFFIX.match(/\d+/)[0] : '1').padStart(3, '0');
const TAG = `[ ${WORKER_NUM} ]`;

// ComfyUI directory resolution
const BASE_COMFY_DIR = existsSync('/app/ComfyUI') ? '/app/ComfyUI' : join(process.cwd(), 'ComfyUI');
const INPUT_DIR = join(BASE_COMFY_DIR, 'input');
const OUTPUT_DIR = join(BASE_COMFY_DIR, 'output');

// Identity & Session Tracking
const MACHINE_ID = os.hostname();
const UNIQUE_WORKER_ID = `${MACHINE_ID}-${WORKER_SUFFIX}`;
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;
const WORKER_SESSION_ID = process.env.WORKER_SESSION_ID || null;

if (!WORKER_API_SECRET) {
  console.error(`${TAG} FATAL: WORKER_API_SECRET environment variable is missing.`);
  process.exit(1);
}

// Track active background uploads to prevent shutdown race conditions
const active_uploads = new Set();

// Telemetry Stats (isolated per worker suffix)
const STATS_FILE = `/tmp/worker_stats_${WORKER_SUFFIX}.json`;
let jobs_processed = 0;
let total_generation_time_sec = 0;

// Backend Configuration & Aliasing
const API_BASE_URL = process.env.API_BASE_URL || 'https://api.runltx.com';
const JOB_TYPE = process.env.JOB_TYPE || 'interpolate';
const MODEL_TYPE = process.env.MODEL || process.env.MODEL_TYPE || 'interpolate-video';
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10) || 1;
const MAX_EMPTY_POLLS = parseInt(process.env.MAX_EMPTY_POLLS, 10) || 3;

// R2 Storage Client Configuration
const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

console.log('====================================================');
console.log(`[Config] Worker Tag:        ${TAG}`);
console.log(`[Config] Worker ID:         ${UNIQUE_WORKER_ID}`);
console.log(`[Config] Session ID:        ${WORKER_SESSION_ID || 'NONE'}`);
console.log(`[Config] Comfy Port:        ${COMFY_PORT}`);
console.log(`[Config] Comfy Host:        ${COMFY_HOST}`);
console.log(`[Config] Workflow JSON:     ${WORKFLOW_PATH}`);
console.log(`[Config] Stats Target:      ${STATS_FILE}`);
console.log(`[Config] Model Target:      ${JOB_TYPE}/${MODEL_TYPE}`);
console.log('====================================================');

if (!R2_ACCOUNT_ID || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET_NAME) {
  console.error(`${TAG} [CRITICAL] Missing required R2 environment variables. Uploads will fail!`);
}

const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID || '',
    secretAccessKey: R2_SECRET_ACCESS_KEY || '',
  },
});

// ============================================
// Helper Functions & Lifecycle Control
// ============================================
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const get_api_headers = () => ({
  'worker-auth': WORKER_API_SECRET,
  'x-machine-id': MACHINE_ID,
  'x-worker-id': UNIQUE_WORKER_ID,
  'content-type': 'application/json'
});

const sync_stats_to_disk = async () => {
  try {
    const payload = JSON.stringify({
      worker: UNIQUE_WORKER_ID,
      jobs_processed,
      total_generation_time_sec: Math.round(total_generation_time_sec * 100) / 100
    });
    await writeFile(STATS_FILE, payload);
  } catch (err) {
    console.warn(`${TAG} Failed to persist stats:`, err.message);
  }
};

const flush_pending_uploads = async () => {
  if (active_uploads.size > 0) {
    console.log(`${TAG} Waiting for ${active_uploads.size} background upload(s) before teardown...`);
    await Promise.allSettled(Array.from(active_uploads));
    console.log(`${TAG} All background uploads resolved.`);
  }
};

const handle_inactivity_shutdown = async () => {
  console.log(`${TAG} Inactivity limit reached. Finalizing...`);
  await flush_pending_uploads();
  await sync_stats_to_disk();
  process.exit(0);
};

// ============================================
// Central Backend API Handshakes
// ============================================
const poll_for_job = async () => {
  try {
    const url = `${API_BASE_URL}/v1/worker/get`;
    const payload = {
      session_id: WORKER_SESSION_ID,
      worker_id: UNIQUE_WORKER_ID,
      slot: WORKER_SUFFIX,
      job_type: JOB_TYPE,
      model: MODEL_TYPE,
      models: MODEL_TYPE
    };

    const response = await fetch(url, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify(payload)
    });

    if (response.status === 404) return null;
    if (!response.ok) {
      const err_text = await response.text();
      throw new Error(`HTTP ${response.status}: ${err_text}`);
    }

    return await response.json();
  } catch (err) {
    console.error(`${TAG} [API Poll Error]:`, err.message);
    return null;
  }
};

const complete_job = async (job_id, output_url, generation_time_sec) => {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const url = `${API_BASE_URL}/v1/worker/complete`;
      const response = await fetch(url, {
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

      if (!response.ok) {
        const err_text = await response.text();
        throw new Error(`HTTP ${response.status}: ${err_text}`);
      }

      jobs_processed += 1;
      total_generation_time_sec += generation_time_sec;
      await sync_stats_to_disk();

      return await response.json();
    } catch (err) {
      console.error(`${TAG} Complete attempt ${attempt}/3 failed: ${err.message}`);
      if (attempt < 3) await sleep(2000);
      else throw err;
    }
  }
};

const fail_job = async (job_id, error_message) => {
  const formatted_error = typeof error_message === 'string'
    ? error_message
    : error_message?.message || JSON.stringify(error_message) || 'Worker failure';

  console.log(`${TAG} Reporting failure for job '${job_id}': ${formatted_error}`);

  try {
    const url = `${API_BASE_URL}/v1/worker/fail`;
    const response = await fetch(url, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        error_message: formatted_error
      }),
    });

    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } catch (err) {
    console.error(`${TAG} Failed reporting error to backend:`, err.message);
  }
};

// ============================================
// ComfyUI Engine Interface
// ============================================
const wait_for_comfy_ready = async () => {
  console.log(`${TAG} Probing ComfyUI on port ${COMFY_PORT}...`);
  while (true) {
    try {
      const res = await fetch(`${COMFY_HOST}/history`);
      if (res.ok) {
        console.log(`${TAG} ComfyUI online on port ${COMFY_PORT}.`);
        break;
      }
    } catch (_) {}
    await sleep(250);
  }
};

const mutate_workflow = (workflow, { input_filename, multiplier = 4 }) => {
  const parsedMultiplier = parseInt(multiplier, 10) || 4;

  // 1. Inject downloaded input video into LoadVideo (Node 4)
  if (workflow['4']?.inputs) {
    workflow['4'].inputs.file = input_filename;
  }

  // 2. Inject multiplier into PrimitiveInt (Node 16:9)
  if (workflow['16:9']?.inputs) {
    workflow['16:9'].inputs.value = parsedMultiplier;
  }

  // 3. Set prefix on SaveVideo (Node 7) to avoid worker file collisions
  if (workflow['7']?.inputs) {
    workflow['7'].inputs.filename_prefix = `video/${WORKER_SUFFIX}_ComfyUI`;
  }

  return workflow;
};

const execute_workflow = async (workflow, job_id) => {
  const response = await fetch(`${COMFY_HOST}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow }),
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`ComfyUI prompt rejected: HTTP ${response.status} - ${err_text}`);
  }

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

        if (job_history.status?.status_str === 'error') {
          const messages = job_history.status.messages || [];
          throw new Error(`ComfyUI execution error: ${JSON.stringify(messages)}`);
        }

        const outputs = job_history.outputs || {};
        for (const nodeId in outputs) {
          const nodeOutput = outputs[nodeId];

          const videos = nodeOutput.videos || nodeOutput.gifs;
          if (videos && videos.length > 0) {
            const vid = videos[0];
            const subfolder = vid.subfolder ? `${vid.subfolder}/` : '';
            const output_path = join(OUTPUT_DIR, `${subfolder}${vid.filename}`);
            return { output_path, duration };
          }

          if (nodeOutput.images && nodeOutput.images.length > 0) {
            const img = nodeOutput.images[0];
            const subfolder = img.subfolder ? `${img.subfolder}/` : '';
            const output_path = join(OUTPUT_DIR, `${subfolder}${img.filename}`);
            return { output_path, duration };
          }
        }

        throw new Error(`ComfyUI finished prompt ${prompt_id} but produced no output videos.`);
      }
    }
  }
};

// ============================================
// Video IO & Storage
// ============================================
const download_video = async (url, filename) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Video download failed: HTTP ${res.status} (${res.statusText})`);

  const buffer = await res.arrayBuffer();
  await mkdir(INPUT_DIR, { recursive: true });
  const target_path = join(INPUT_DIR, filename);
  await writeFile(target_path, Buffer.from(buffer));
  return target_path;
};

const upload_to_r2 = async (file_path, job_id) => {
  if (!existsSync(file_path)) {
    throw new Error(`File not found for R2 upload: ${file_path}`);
  }

  const ext = file_path.endsWith('.webm') ? 'webm' : 'mp4';
  const key = `interpolations/${job_id}.${ext}`;
  const contentType = ext === 'webm' ? 'video/webm' : 'video/mp4';
  const file_stream = createReadStream(file_path);

  await s3_client.send(new PutObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key,
    Body: file_stream,
    ContentType: contentType,
  }));

  return `${R2_CDN_URL}/${key}`;
};

const upload_and_complete_async = async (job_id, isolated_path, input_paths = [], duration) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id);
    await complete_job(job_id, r2_url, duration);
    console.log(`${TAG} \x1b[32m✔\x1b[0m Job [${job_id}] finished in ${duration.toFixed(1)}s -> ${r2_url}`);
  } catch (err) {
    console.error(`${TAG} [Job ${job_id}] Upload/Complete failed:`, err.message);
    try { await fail_job(job_id, err.message); } catch (_) {}
  } finally {
    if (isolated_path) {
      try { await unlink(isolated_path); } catch (_) {}
    }
    for (const path of input_paths) {
      if (path) {
        try { await unlink(path); } catch (_) {}
      }
    }
  }
};

// ============================================
// Pipeline Step: Prepare & Prefetch Job
// ============================================
const prepare_job = async (job_data) => {
  const { job_id } = job_data;
  const input = job_data.input || {};
  const video_url = input.video_url || job_data.video_url;
  const multiplier = input.multiplier || job_data.multiplier || 4;

  if (!video_url) {
    throw new Error(`Job ${job_id} is missing required 'video_url' field.`);
  }

  const ext = video_url.includes('.webm') ? 'webm' : 'mp4';
  const input_filename = `${WORKER_SUFFIX}_${job_id}_input.${ext}`;
  const input_path = await download_video(video_url, input_filename);
  const downloaded_paths = [input_path];

  const raw_workflow = JSON.parse(readFileSync(WORKFLOW_PATH, 'utf-8'));
  const workflow = mutate_workflow(raw_workflow, { input_filename, multiplier });

  return { job_id, workflow, downloaded_paths, video_url };
};

const prefetch_next_job = async () => {
  try {
    const result = await poll_for_job();
    if (!result || !result.success || !result.data) {
      return null;
    }

    try {
      const prepared = await prepare_job(result.data);
      console.log(`${TAG} [Prefetched Job ${prepared.job_id}] Input: ${prepared.video_url}`);
      return prepared;
    } catch (prep_err) {
      console.error(`${TAG} [Job ${result.data.job_id}] Prep failed:`, prep_err.message);
      try { await fail_job(result.data.job_id, prep_err.message); } catch (_) {}
      return null;
    }
  } catch (err) {
    console.error(`${TAG} [Pipeline] Prefetch error:`, err.message);
    return null;
  }
};

// ============================================
// Main Execution Loop
// ============================================
const worker_loop = async () => {
  console.log(`${TAG} Daemon active on ${UNIQUE_WORKER_ID}`);

  await mkdir(INPUT_DIR, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });
  await sync_stats_to_disk();
  await wait_for_comfy_ready();

  let current_job = null;
  let prefetch_promise = null;
  let empty_poll_count = 0;

  console.log(`${TAG} Polling every ${POLL_INTERVAL_SECONDS}s...`);

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
        if (empty_poll_count % 5 === 0 || empty_poll_count === 1) {
          console.log(`${TAG} Queue empty (${empty_poll_count}/${MAX_EMPTY_POLLS})`);
        }

        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          await handle_inactivity_shutdown();
        }

        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      console.log(`${TAG} [GPU Render Job ${current_job.job_id}] Interpolating 4x...`);

      // Prefetch next video concurrently while this stream runs on the GPU
      prefetch_promise = prefetch_next_job();

      try {
        const { output_path: generated_file, duration } = await execute_workflow(current_job.workflow, current_job.job_id);

        const ext = generated_file.endsWith('.webm') ? 'webm' : 'mp4';
        const isolated_path = join(OUTPUT_DIR, `uploading_${WORKER_SUFFIX}_${current_job.job_id}.${ext}`);
        await rename(generated_file, isolated_path);

        console.log(`${TAG} [Job ${current_job.job_id}] Rendered in ${duration.toFixed(2)}s. Offloading to upload queue.`);

        const upload_task = upload_and_complete_async(
          current_job.job_id,
          isolated_path,
          current_job.downloaded_paths,
          duration
        );
        active_uploads.add(upload_task);
        upload_task.finally(() => active_uploads.delete(upload_task));

      } catch (render_err) {
        console.error(`${TAG} [Job ${current_job.job_id}] Render failed:`, render_err.message);
        for (const path of current_job.downloaded_paths) {
          if (path) {
            try { await unlink(path); } catch (_) {}
          }
        }
        try { await fail_job(current_job.job_id, render_err.message); } catch (_) {}
      }

      current_job = null;

    } catch (err) {
      console.error(`${TAG} Error in loop:`, err.message);
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

const handle_exit = async () => {
  console.log(`${TAG} Termination signal received.`);
  await flush_pending_uploads();
  await sync_stats_to_disk();
  process.exit(0);
};

process.on('SIGINT', handle_exit);
process.on('SIGTERM', handle_exit);

worker_loop().catch((err) => {
  console.error(`${TAG} Fatal:`, err);
  process.exit(1);
});