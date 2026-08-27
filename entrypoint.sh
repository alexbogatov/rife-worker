#!/usr/bin/env bash
set -eo pipefail

export GIT_TERMINAL_PROMPT=0

echo "===================================================="
echo "[Startup] Initializing RIFE Interpolation Worker"
echo "===================================================="

# ==============================================================================
# 1. Platform & GPU Auto-Discovery
# ==============================================================================
if [ -n "$SALAD_CONTAINER_GROUP_ID" ] || [ -n "$SALAD_MACHINE_ID" ]; then
    export RUNNER_PLATFORM="saladcloud"
elif [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ] || [ -n "$MODAL_ENVIRONMENT" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$HYPERSTACK_API_KEY" ]; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="saladcloud"
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

echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($RUNNER_GPU_COUNT detected, $RUNNER_GPU_VRAM VRAM)"
echo "===================================================="

# ==============================================================================
# 2. Register Startup Session via /v1/worker/on
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
# 3. Environment & Storage Cleanliness
# ==============================================================================
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true

mkdir -p /app/ComfyUI/input \
         /app/ComfyUI/output

# ==============================================================================
# 4. Launch ComfyUI & Worker Daemon
# ==============================================================================
cd /app

# Determine Python runtime path (venv or system python)
if [ -f "/opt/venv/bin/python3" ]; then
    PYTHON_BIN="/opt/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi

echo "[Startup] Starting ComfyUI backend..."
$PYTHON_BIN /ComfyUI/main.py --listen 0.0.0.0 --port 8188 --fast &
COMFY_PID=$!

echo "[Startup] Waiting for ComfyUI on port 8188..."
until curl -s http://127.0.0.1:8188/system_stats > /dev/null 2>&1; do
    sleep 1
done
echo "[Startup] ComfyUI ready. Launching worker daemon..."

# Execute worker (handles queue polling until inactivity timeout)
node worker.js
WORKER_EXIT_CODE=$?

# Terminate ComfyUI process
kill -9 $COMFY_PID 2>/dev/null || true

# ==============================================================================
# 5. Teardown & Session Finalization via /v1/worker/off
# ==============================================================================
echo "[Billing] Finalizing worker session via /v1/worker/off..."

STATS_FILE="/tmp/worker_stats.json"
JOBS_PROCESSED=0
TOTAL_GEN_TIME=0

if [ -f "$STATS_FILE" ]; then
    JOBS_PROCESSED=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).jobs_processed || 0); } catch(_) { console.log(0); }")
    TOTAL_GEN_TIME=$(node -e "try { console.log(JSON.parse(fs.readFileSync('$STATS_FILE')).total_generation_time_sec || 0); } catch(_) { console.log(0); }")
fi

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

echo "[Billing] Session closed. Container shutting down."

if [ "$RUNNER_PLATFORM" = "saladcloud" ]; then
    echo "[Teardown] Sending reallocate signal to SaladCloud runtime..."
    curl -s -X POST "http://169.254.169.254/v1/reallocate" || true
fi

exit $WORKER_EXIT_CODE