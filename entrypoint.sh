#!/bin/bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

# ==============================================================================
# Global Logging & Initialization
# ==============================================================================
LOG_DIR="${LOG_DIR:-/var/log/runner}"
mkdir -p "${LOG_DIR}"

# Mirror entrypoint stdout/stderr to disk and terminal
exec > >(tee -a "${LOG_DIR}/entrypoint.log") 2>&1

TOTAL_INSTANCES="${INSTANCES:-12}"

echo "===================================================="
echo "[Startup] Initializing ${TOTAL_INSTANCES}x Parallel ComfyUI Workers"
echo "===================================================="

# ==============================================================================
# 1. Platform & GPU Auto-Discovery
# ==============================================================================

is_hyperstack() {
    if curl -s --connect-timeout 1 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    local dmi_data
    dmi_data="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || true)"
    if echo "$dmi_data" | grep -qi "nexgen\|hyperstack"; then
        return 0
    fi

    if [ -d "/etc/hyperstack" ] || [ -f "/var/log/hyperstack-init.log" ] || [ -n "$HYPERSTACK_API_KEY" ]; then
        return 0
    fi

    return 1
}

# Auto-Discovery Priority
if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ] || [ -n "$MODAL_ENVIRONMENT" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$VAST_CONTAINERLABEL" ] || [ -n "$CONTAINER_ID" ] || [ -n "$VAST_TCP_PORT_22" ]; then
    export RUNNER_PLATFORM="vastai"
elif [ -n "$RUNPOD_POD_ID" ]; then
    export RUNNER_PLATFORM="runpod"
elif is_hyperstack; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="generic"
fi

if command -v nvidia-smi &> /dev/null; then
    export RUNNER_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)
    export RUNNER_GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | xargs)
    export RUNNER_GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1 | xargs)
else
    export RUNNER_GPU_NAME="None"
    export RUNNER_GPU_COUNT="0"
    export RUNNER_GPU_VRAM="0"
fi

MACHINE_ID=$(hostname)
API_BASE_URL="${API_BASE_URL:-https://api.runltx.com}"
HYPERSTACK_VM_NAME="${VM_NAME:-${MACHINE_ID}}"

echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($RUNNER_GPU_COUNT detected, $RUNNER_GPU_VRAM VRAM)"
echo "===================================================="

# ==============================================================================
# 2. CALL /v1/worker/on (Register startup session)
# ==============================================================================
echo "[Billing] Registering worker startup session via /v1/worker/on..."
SESSION_PAYLOAD=$(cat <<EOF
{
  "machine_id": "${MACHINE_ID}",
  "provider": "${RUNNER_PLATFORM}",
  "gpu_name": "${RUNNER_GPU_NAME}",
  "gpu_count": ${RUNNER_GPU_COUNT},
  "gpu_vram": "${RUNNER_GPU_VRAM}"
}
EOF
)

SESSION_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/v1/worker/on" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${SESSION_PAYLOAD}" || echo '{"success":false}')

export WORKER_SESSION_ID=$(echo "$SESSION_RESPONSE" | node -e "
    const fs = require('fs');
    try {
        const res = JSON.parse(fs.readFileSync(0, 'utf-8'));
        if (res.success && res.session_id) process.stdout.write(res.session_id);
    } catch (_) {}
")

if [ -n "$WORKER_SESSION_ID" ]; then
    echo "[Billing] Active Worker Session ID: ${WORKER_SESSION_ID}"
else
    echo "[Billing Warning] Could not initialize session tracking."
fi

# ==============================================================================
# 3. Storage Setup & Symlinks
# ==============================================================================
PERSISTENT_DIR="${PERSISTENT_STORAGE_DIR:-/workspace}"
MODEL_DIR="${PERSISTENT_DIR}/ComfyUI/models"

mkdir -p "${MODEL_DIR}/diffusion_models" \
         "${MODEL_DIR}/clip" \
         "${MODEL_DIR}/vae" \
         "${PERSISTENT_DIR}/ComfyUI/input" \
         "${PERSISTENT_DIR}/ComfyUI/output"

rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

rm -f /tmp/worker_stats_*.json /tmp/worker_stats.json

# ==============================================================================
# 4. Model Downloads (RIFE Heavy Weights)
# ==============================================================================
download_if_missing() {
    local target_dir="$1"
    local file_name="$2"
    local url="$3"

    mkdir -p "${target_dir}"

    if [ -f "${target_dir}/${file_name}" ]; then
        echo "[Storage] Found '${file_name}' on persistent storage. Skipping download."
    else
        echo "[Storage] Missing '${file_name}'. Downloading via aria2..."
        
        local ARIA_AUTH=()
        if [ -n "$HF_TOKEN" ]; then
            ARIA_AUTH=(--header="Authorization: Bearer ${HF_TOKEN}")
        fi

        if ! aria2c -x 8 -s 8 -k 1M \
            --async-dns=false \
            --max-tries=5 \
            --retry-wait=2 \
            "${ARIA_AUTH[@]}" \
            -d "${target_dir}" -o "${file_name}" "${url}"; then
            
            echo "[Storage Warning] aria2c failed. Falling back to wget..."
            
            if [ -n "$HF_TOKEN" ]; then
                wget --quiet --show-progress -c --header="Authorization: Bearer ${HF_TOKEN}" -O "${target_dir}/${file_name}" "${url}"
            else
                wget --quiet --show-progress -c -O "${target_dir}/${file_name}" "${url}"
            fi
        fi
    fi
}

download_if_missing "${MODEL_DIR}" "rife_v4.26_heavy.safetensors" "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26_heavy.safetensors"

# ==============================================================================
# 5. Launch N ComfyUI & N Node Daemons in Parallel
# ==============================================================================
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true
cd /app

export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-garbage_collection_threshold:0.8,max_split_size_mb:128}"

BASE_PORT=8188
COMFY_PIDS=()
WORKER_PIDS=()

echo "[Startup] Spawning ${TOTAL_INSTANCES} ComfyUI instances (ports ${BASE_PORT} to $((BASE_PORT + TOTAL_INSTANCES - 1)))..."

for i in $(seq 1 "$TOTAL_INSTANCES"); do
    PORT=$((BASE_PORT + i - 1))
    /opt/venv/bin/python3 /app/ComfyUI/main.py \
        --listen 0.0.0.0 --port "${PORT}" --gpu-only --fast --use-sage-attention --disable-auto-launch \
        > "${LOG_DIR}/comfy_${i}.log" 2>&1 &
    COMFY_PIDS+=($!)
done

echo "[Startup] Waiting for all ${TOTAL_INSTANCES} ComfyUI endpoints to respond..."
for i in $(seq 1 "$TOTAL_INSTANCES"); do
    PORT=$((BASE_PORT + i - 1))
    until curl -s "http://127.0.0.1:${PORT}/history" > /dev/null 2>&1; do
        sleep 1
    done
done
echo "[Startup] All ${TOTAL_INSTANCES} ComfyUI runtimes online."

echo "[Startup] Launching ${TOTAL_INSTANCES} Node.js workers..."
for i in $(seq 1 "$TOTAL_INSTANCES"); do
    PORT=$((BASE_PORT + i - 1))
    COMFY_PORT="${PORT}" WORKER_SUFFIX="worker_${i}" node worker.js > "${LOG_DIR}/worker_${i}.log" 2>&1 &
    WORKER_PIDS+=($!)
done

echo "[Startup] All ${TOTAL_INSTANCES} workers running. Tail logs with:"
echo "  tail -fn +1 ${LOG_DIR}/worker_*.log"
echo "  tail -f ${LOG_DIR}/entrypoint.log"

# Await workers completion
WORKER_EXIT_CODE=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" || WORKER_EXIT_CODE=$?
done

# Teardown ComfyUI instances
kill -9 "${COMFY_PIDS[@]}" 2>/dev/null || true

# ==============================================================================
# 6. Aggregate Stats & Finalize Session
# ==============================================================================
echo "[Billing] Finalizing worker session via /v1/worker/off..."

STATS_DATA=$(node -e "
    const fs = require('fs');
    const path = require('path');
    let jobs = 0;
    let duration = 0;
    try {
        const files = fs.readdirSync('/tmp').filter(f => f.startsWith('worker_stats_') && f.endsWith('.json'));
        if (fs.existsSync('/tmp/worker_stats.json')) files.push('worker_stats.json');
        for (const f of files) {
            try {
                const data = JSON.parse(fs.readFileSync(path.join('/tmp', f), 'utf8'));
                jobs += data.jobs_processed || 0;
                duration += data.total_generation_time_sec || 0;
            } catch (_) {}
        }
    } catch (_) {}
    console.log(JSON.stringify({ jobs, duration: Math.round(duration) }));
")

JOBS_PROCESSED=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(0,'utf-8')); console.log(d.jobs || 0);")
TOTAL_GEN_TIME=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(0,'utf-8')); console.log(d.duration || 0);")

OFF_PAYLOAD=$(cat <<EOF
{
  "session_id": "${WORKER_SESSION_ID}",
  "machine_id": "${MACHINE_ID}",
  "jobs_processed": ${JOBS_PROCESSED},
  "total_generation_time_sec": ${TOTAL_GEN_TIME}
}
EOF
)

curl -s -X POST "${API_BASE_URL}/v1/worker/off" \
    -H "Content-Type: application/json" \
    -H "worker-auth: ${WORKER_API_SECRET}" \
    -H "x-machine-id: ${MACHINE_ID}" \
    -d "${OFF_PAYLOAD}" || true

echo "[Billing] Session closed. Jobs: ${JOBS_PROCESSED}, Total Time: ${TOTAL_GEN_TIME}s."

# ==============================================================================
# 7. Cloud Teardown & Auto-Shutdown (Instance-level)
# ==============================================================================

# --- Hyperstack Hibernation ---
if [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
    echo "[Teardown] Requesting Hyperstack VM Hibernation for host: ${HYPERSTACK_VM_NAME}..."
    HYPERSTACK_API_URL="${HYPERSTACK_API_URL:-https://infrahub-api.nexgencloud.com/v1}"
    
    VM_ID=$(curl -s -H "api_key: ${HYPERSTACK_API_KEY}" -H "accept: application/json" \
        "${HYPERSTACK_API_URL}/core/virtual-machines" | \
        node -e "
            const fs = require('fs');
            try {
                const data = JSON.parse(fs.readFileSync(0, 'utf-8'));
                const match = (data.instances || []).find(v => v.name && v.name.toLowerCase() === '${HYPERSTACK_VM_NAME}'.toLowerCase());
                if (match) process.stdout.write(String(match.id));
            } catch (_) {}
        ")

    if [ -n "$VM_ID" ]; then
        echo "[Teardown] Hibernating VM ${VM_ID}..."
        curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
            "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true
    fi

# --- Vast.ai Stop Instance ---
elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
    echo "[Teardown] Shutting down Vast.ai instance to prevent idle compute charges..."
    
    VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"

    if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling Vast.ai REST API for instance ${VAST_ID}..."
        curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
            -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"state": "stopped"}' || true
    elif command -v vastai >/dev/null 2>&1 && [ -n "$VAST_ID" ]; then
        echo "[Teardown] Calling vastai CLI for instance ${VAST_ID}..."
        vastai stop instance "$VAST_ID" || true
    else
        echo "[Teardown] Terminating PID 1..."
        kill -s TERM 1 2>/dev/null || true
    fi
fi

exit $WORKER_EXIT_CODE