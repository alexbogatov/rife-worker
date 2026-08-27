// worker.js

import os from 'os';
import { readFileSync, createReadStream } from 'fs';
import { mkdir, writeFile, readdir, stat, unlink, rename } from 'fs/promises';
import { join } from 'path';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

const WORKER_SESSION_ID = process.env.WORKER_SESSION_ID;

// ============================================
// CONSTANTS & IDENTITY
// ============================================
const COMFY_PORT = 8188;
const COMFY_HOST = `http://127.0.0.1:${COMFY_PORT}`;
const WORKFLOW_MAP = {
  'rife': join(process.cwd(), 'rife.json')
};
const INPUT_DIR = join(process.cwd(), 'ComfyUI', 'input');
const OUTPUT_DIR = join(process.cwd(), 'ComfyUI', 'output');
const STATS_FILE = '/tmp/worker_stats.json';

// Machine identity and static secret from environment
const MACHINE_ID = os.hostname();
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;

// Track background upload tasks
const active_uploads = new Set();

// Telemetry counters
let total_jobs_processed = 0;
let total_generation_time_sec = 0;

// API Configuration
const API_BASE_URL = process.env.API_BASE_URL || 'https://api.runltx.com';
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10) || 1;
const MAX_EMPTY_POLLS = 3;

// R2 Configuration
const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

if (!R2_ACCOUNT_ID || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET_NAME) {
  console.warn('[Config Warning] Missing one or more R2 credentials.');
}

// ============================================
// R2 Client
// ============================================
const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID || '',
    secretAccessKey: R2_SECRET_ACCESS_KEY || '',
  },
});

// ============================================
// Helper Functions
// ============================================
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const get_api_headers = () => ({
  'worker-auth': WORKER_API_SECRET,
  'x-machine-id': MACHINE_ID,
  'content-type': 'application/json'
});

const sync_stats_file = async () => {
  try {
    const stats = {
      jobs_processed: total_jobs_processed,
      total_generation_time_sec: Math.round(total_generation_time_sec * 100) / 100,
    };
    await writeFile(STATS_FILE, JSON.stringify(stats));
  } catch (_) {}
};

const format_job_log = (meta) => {
  return `[ ${meta.job_id} ] model: ${meta.model} | multiplier: ${meta.multiplier}x | video: ${meta.video_filename}`;
};

const flush_pending_uploads = async () => {
  if (active_uploads.size > 0) {
    console.log(`[Worker] Waiting for ${active_uploads.size} background upload(s) to finalize...`);
    await Promise.allSettled(Array.from(active_uploads));
    console.log('[Worker] All uploads resolved.');
  }
  await sync_stats_file();
};

const handle_inactivity_shutdown = async () => {
  console.log('[Worker] Inactivity limit reached. Initiating teardown...');
  await flush_pending_uploads();
  process.exit(0);
};

// ============================================
// API Operations
// ============================================
const poll_for_job = async (job_type, model) => {
  try {
    const url = `${API_BASE_URL}/v1/worker/get`;
    const response = await fetch(url, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        job_type,
        models: model
      })
    });

    if (response.status === 404) return null;

    if (!response.ok) {
      const err_text = await response.text();
      throw new Error(`HTTP ${response.status}: ${err_text}`);
    }

    return await response.json();
  } catch (err) {
    console.error('[API Poll Error]:', err.message);
    return null;
  }
};

const complete_job = async (job_id, output_url, generation_time_sec) => {
  const url = `${API_BASE_URL}/v1/worker/complete`;
  const response = await fetch(url, {
    method: 'POST',
    headers: get_api_headers(),
    body: JSON.stringify({
      session_id: WORKER_SESSION_ID,
      job_id,
      output_url,
      generation_time_sec
    })
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`HTTP ${response.status}: ${err_text}`);
  }

  return await response.json();
};

const fail_job = async (job_id, error_message) => {
  const url = `${API_BASE_URL}/v1/worker/fail`;
  const response = await fetch(url, {
    method: 'POST',
    headers: get_api_headers(),
    body: JSON.stringify({
      session_id: WORKER_SESSION_ID,
      job_id,
      error_message: typeof error_message === 'string' ? error_message : (error_message?.message || 'Worker failure')
    })
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`HTTP ${response.status}: ${err_text}`);
  }

  return await response.json();
};

// ============================================
// ComfyUI Engine
// ============================================
const wait_for_comfy_ready = async () => {
  console.log('[ComfyUI] Probing server readiness on port 8188...');
  const health_url = `${COMFY_HOST}/history`;

  while (true) {
    try {
      const res = await fetch(health_url);
      if (res.ok) {
        console.log('[ComfyUI] Server online and responsive.');
        break;
      }
    } catch (_) {}
    await sleep(250);
  }
};

const mutate_workflow = (workflow, video_filename, multiplier = 4) => {
  for (const [, node] of Object.entries(workflow)) {
    // 1. Inject Input Video into LoadVideo Node
    if (node.class_type === 'LoadVideo') {
      node.inputs.file = video_filename;
    }

    // 2. Inject Interpolation Multiplier
    if (node.class_type === 'PrimitiveInt' && node._meta?.title === 'Int (Multiplier)') {
      node.inputs.value = multiplier;
    }
  }

  return workflow;
};

const execute_workflow = async (workflow) => {
  const response = await fetch(`${COMFY_HOST}/prompt`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: workflow }),
  });

  if (!response.ok) {
    const err_text = await response.text();
    throw new Error(`Workflow rejection: ${response.status} - ${err_text}`);
  }

  const { prompt_id } = await response.json();
  const start_time = Date.now();

  while (true) {
    await sleep(250);
    const history_res = await fetch(`${COMFY_HOST}/history/${prompt_id}`);

    if (history_res.ok) {
      const history_data = await history_res.json();
      if (history_data[prompt_id]) {
        return (Date.now() - start_time) / 1000;
      }
    }
  }
};

// ============================================
// Filesystem & Storage Operations
// ============================================
const find_latest_mp4 = async (dir) => {
  const files = [];
  const walk = async (current_dir) => {
    try {
      const entries = await readdir(current_dir, { withFileTypes: true });
      for (const entry of entries) {
        const full_path = join(current_dir, entry.name);
        if (entry.isDirectory()) {
          await walk(full_path);
        } else if (entry.name.endsWith('.mp4') && !entry.name.startsWith('uploading_')) {
          const stats = await stat(full_path);
          files.push({ path: full_path, mtime: stats.mtime });
        }
      }
    } catch (_) {}
  };

  await walk(dir);
  if (files.length === 0) return null;
  files.sort((a, b) => b.mtime.getTime() - a.mtime.getTime());
  return files[0].path;
};

const download_video = async (url, filename) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Video download failed: ${res.statusText}`);
  const buffer = await res.arrayBuffer();
  await mkdir(INPUT_DIR, { recursive: true });
  const video_path = join(INPUT_DIR, filename);
  await writeFile(video_path, Buffer.from(buffer));
  return video_path;
};

const upload_to_r2 = async (file_path, job_id) => {
  const key = `interpolations/${job_id}.mp4`;
  const file_stream = createReadStream(file_path);

  await s3_client.send(new PutObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key,
    Body: file_stream,
    ContentType: 'video/mp4',
  }));

  return `${R2_CDN_URL}/${key}`;
};

const upload_and_complete_async = async (job_id, isolated_path, generation_time, downloaded_filename) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id);
    await complete_job(job_id, r2_url, generation_time);
    console.log(`[Job ${job_id}] Upload & complete finished in background.`);
  } catch (err) {
    console.error(`[Job ${job_id}] Background upload/complete failed:`, err.message);
    try { await fail_job(job_id, err.message); } catch (_) {}
  } finally {
    try { await unlink(isolated_path); } catch (_) {}
    if (downloaded_filename) {
      try { await unlink(join(INPUT_DIR, downloaded_filename)); } catch (_) {}
    }
  }
};

// ============================================
// Pipeline Step: Fetch & Prepare Task
// ============================================
const prepare_job = async (job_data) => {
  const { job_id, job_type, model, input } = job_data;

  const video_url = input?.video_url ?? job_data.video_url;
  if (!video_url) {
    throw new Error('No valid video URL found in job payload');
  }

  const multiplier = parseInt(input?.multiplier ?? job_data.multiplier ?? 4, 10);
  const model_id = model || 'rife';
  const workflow_path = WORKFLOW_MAP[model_id];

  if (!workflow_path) {
    throw new Error(`Unsupported model identifier: ${model_id}`);
  }

  const video_filename = `${job_id}.mp4`;
  await download_video(video_url, video_filename);

  const raw_workflow = readFileSync(workflow_path, 'utf-8');
  let workflow = JSON.parse(raw_workflow);

  workflow = mutate_workflow(workflow, video_filename, multiplier);

  return {
    job_id,
    job_type,
    model: model_id,
    workflow,
    downloaded_filename: video_filename,
    meta: {
      job_id,
      model: model_id,
      multiplier,
      video_filename
    }
  };
};

const prefetch_next_job = async (job_type, model) => {
  try {
    const result = await poll_for_job(job_type, model);
    if (!result || !result.success || !result.data) {
      return null;
    }

    try {
      const prepared_job = await prepare_job(result.data);
      console.log(`[Prefetched] ${format_job_log(prepared_job.meta)}`);
      return prepared_job;
    } catch (prep_err) {
      console.error(`[Job ${result.data.job_id}] Preparation failed:`, prep_err.message);
      try { await fail_job(result.data.job_id, prep_err.message); } catch (_) {}
      return null;
    }
  } catch (err) {
    console.error('[Pipeline] Prefetch error:', err.message);
    return null;
  }
};

// ============================================
// Main Execution Loop
// ============================================
const worker_loop = async () => {
  console.log(`[Worker] Started on host: ${MACHINE_ID}`);

  if (!WORKER_API_SECRET) {
    console.error('[Worker Fatal] WORKER_API_SECRET environment variable is missing.');
    process.exit(1);
  }

  await mkdir(INPUT_DIR, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });
  await sync_stats_file();

  await wait_for_comfy_ready();

  const job_type = process.env.JOB_TYPE || 'interpolate';
  const model = process.env.MODEL || 'rife';

  let current_job = null;
  let prefetch_promise = null;
  let empty_poll_count = 0;

  console.log(`[Worker] Polling for jobs (type: ${job_type}, model: ${model}) every ${POLL_INTERVAL_SECONDS}s...`);

  while (true) {
    try {
      // 1. Resolve or fetch the active job to process
      if (prefetch_promise) {
        current_job = await prefetch_promise;
        prefetch_promise = null;
      }

      if (!current_job) {
        current_job = await prefetch_next_job(job_type, model);
      }

      // 2. Inactivity tracking
      if (!current_job) {
        empty_poll_count++;
        console.log(`[Worker] No jobs available (${empty_poll_count}/${MAX_EMPTY_POLLS})`);

        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          await handle_inactivity_shutdown();
        }

        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      console.log(`[GPU Interpolate] ${format_job_log(current_job.meta)}`);

      // 3. Kick off prefetch for next job in parallel with GPU interpolation
      prefetch_promise = prefetch_next_job(job_type, model);

      // 4. Render Job
      let generation_time = 0;
      let render_success = false;

      try {
        generation_time = await execute_workflow(current_job.workflow);
        render_success = true;
      } catch (render_err) {
        console.error(`[Job ${current_job.job_id}] Interpolation failed:`, render_err.message);
        try { await fail_job(current_job.job_id, render_err.message); } catch (_) {}
      }

      // 5. Isolate MP4 & delegate upload to non-blocking background task
      if (render_success) {
        const output_file = await find_latest_mp4(OUTPUT_DIR);
        if (output_file) {
          const isolated_path = join(OUTPUT_DIR, `uploading_${current_job.job_id}.mp4`);
          await rename(output_file, isolated_path);

          total_jobs_processed++;
          total_generation_time_sec += generation_time;
          await sync_stats_file();

          console.log(`[Job ${current_job.job_id}] Interpolated in ${generation_time.toFixed(2)}s. Queuing async upload.`);
          const upload_task = upload_and_complete_async(
            current_job.job_id,
            isolated_path,
            generation_time,
            current_job.downloaded_filename
          );
          active_uploads.add(upload_task);
          upload_task.finally(() => active_uploads.delete(upload_task));
        } else {
          console.error(`[Job ${current_job.job_id}] Output MP4 was not found.`);
          try { await fail_job(current_job.job_id, 'Generated MP4 missing'); } catch (_) {}
        }
      }

      current_job = null;

    } catch (err) {
      console.error('[Worker] Unexpected error in main loop:', err.message);
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

const handle_exit = async () => {
  console.log('[Worker] Termination signal received.');
  await flush_pending_uploads();
  process.exit(0);
};

process.on('SIGINT', handle_exit);
process.on('SIGTERM', handle_exit);

worker_loop().catch((err) => {
  console.error('[Worker] Fatal error:', err);
  process.exit(1);
});