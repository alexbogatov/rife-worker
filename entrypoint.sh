#!/bin/bash
set -eo pipefail

START_BOOT_TIME=$(date +%s)
export GIT_TERMINAL_PROMPT=0

# ==============================================================================
# Global Logging & Paths
# ==============================================================================
LOG_DIR="${LOG_DIR:-/var/log/runner}"
mkdir -p "${LOG_DIR}"

exec > >(tee -a "${LOG_DIR}/entrypoint.log") 2>&1

echo "===================================================="
echo "[Startup] Bootstrapping Multi-GPU ComfyUI Pipeline"
echo "===================================================="

# Diagnostic check: verify worker.js is JavaScript
if head -n 3 /app/worker.js 2>/dev/null | grep -qi "pipefail\|bash\|bin"; then
    echo "[CRITICAL ERROR] /app/worker.js contains shell script code! Aborting."
    sleep 3600
    exit 1
fi

# ==============================================================================
# Pre-Flight Environment Validation
# ==============================================================================
REQUIRED_VARS=(
    "API_BASE_URL"
    "WORKER_API_SECRET"
    "JOB_TYPE"
    "MODEL"
    "POLL_INTERVAL_SECONDS"
    "MAX_EMPTY_POLLS"
    "R2_ACCOUNT_ID"
    "R2_ACCESS_KEY_ID"
    "R2_SECRET_ACCESS_KEY"
    "R2_BUCKET_NAME"
    "R2_CDN_URL"
)

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING+=("$var")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[FATAL] Missing required environment variables in entrypoint.sh:"
    for m in "${MISSING[@]}"; do
        echo "  - $m"
    done
    exit 1
fi

# ==============================================================================
# 1. Platform & Hardware Discovery
# ==============================================================================
discover_lium_pod_id() {
    [ -z "$LIUM_API_KEY" ] && return 1
    local lium_base="${LIUM_BASE_URL:-https://lium.io/api}"

    python3 -c '
import json, urllib.request, socket, sys
api_key, base_url, host = sys.argv[1], sys.argv[2], socket.gethostname().strip().lower()
req = urllib.request.Request(f"{base_url}/pods", headers={"X-API-Key": api_key, "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode())
        pods = data if isinstance(data, list) else data.get("data", data.get("pods", []))
        for p in pods:
            containers = p.get("executor", {}).get("specs", {}).get("docker", {}).get("containers", [])
            if any(c.get("container_id", "").lower().startswith(host) for c in containers):
                sys.stdout.write(str(p.get("id") or p.get("uuid") or p.get("pod_id", "")))
                sys.exit(0)
        if len(pods) == 1:
            sys.stdout.write(str(pods[0].get("id") or pods[0].get("uuid") or pods[0].get("pod_id", "")))
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$LIUM_API_KEY" "$lium_base"
}

is_hyperstack() {
    curl -s --connect-timeout 1 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | grep -qi "nexgen\|hyperstack" && return 0
    cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null | grep -qi "nexgen\|hyperstack" && return 0
    [ -d "/etc/hyperstack" ] || [ -f "/var/log/hyperstack-init.log" ] || [ -n "$HYPERSTACK_API_KEY" ] && return 0
    return 1
}

if [ -n "$MODAL_TASK_ID" ] || [ -n "$MODAL_IS_REMOTE" ]; then
    export RUNNER_PLATFORM="modal"
elif [ -n "$VAST_CONTAINERLABEL" ] || [ -n "$CONTAINER_ID" ] || [ -n "$VAST_TCP_PORT_22" ]; then
    export RUNNER_PLATFORM="vastai"
elif [ -n "$RUNPOD_POD_ID" ]; then
    export RUNNER_PLATFORM="runpod"
elif LIUM_DISCOVERED=$(discover_lium_pod_id); then
    export LIUM_POD_ID="$LIUM_DISCOVERED"
    export RUNNER_PLATFORM="lium"
    echo "[Platform] Verified Lium Pod ID: ${LIUM_POD_ID}"
elif is_hyperstack; then
    export RUNNER_PLATFORM="hyperstack"
else
    export RUNNER_PLATFORM="generic"
fi

if command -v nvidia-smi &> /dev/null; then
    export RUNNER_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1 | xargs)
    export RUNNER_GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | xargs)
    export RUNNER_GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n 1 | tr -d '[:space:]' | xargs)
else
    export RUNNER_GPU_NAME="None"
    export RUNNER_GPU_COUNT="1"
    export RUNNER_GPU_VRAM="0"
fi

NUM_GPUS="${RUNNER_GPU_COUNT:-1}"
[ "$NUM_GPUS" -lt 1 ] && NUM_GPUS=1

# ==============================================================================
# Dynamic Instance Plan Generation
# ==============================================================================
PLAN_JSON=$(node -e '
const cp = require("child_process");
let vramList = [49152];
try {
    const smi = cp.execSync("nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits", {encoding: "utf8"});
    vramList = smi.trim().split("\n").map(x => parseInt(x.trim())).filter(x => !isNaN(x));
} catch(e) {}

let plan = [];
let globalIdx = 1;
const basePort = 8188;

vramList.forEach((vram, gpuIdx) => {
    let workers = Math.max(1, Math.floor(vram / 15000));
    for (let w = 0; w < workers; w++) {
        plan.push({
            instance: globalIdx,
            gpu: gpuIdx,
            port: basePort + globalIdx - 1
        });
        globalIdx++;
    }
});
console.log(JSON.stringify(plan));
')

TOTAL_INSTANCES=$(echo "$PLAN_JSON" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf8')).length);")
MACHINE_ID=$(hostname)
HYPERSTACK_VM_NAME="${VM_NAME:-${MACHINE_ID}}"

echo "===================================================="
echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($NUM_GPUS detected)"
echo "[Hardware] Scaling  : Planned ${TOTAL_INSTANCES} instance(s) across GPU(s)"
echo "===================================================="

# ==============================================================================
# 2. Session Initialization (/v1/worker/on)
# ==============================================================================
echo "[Billing] Registering worker startup session via /v1/worker/on..."
SESSION_PAYLOAD=$(cat <<EOF
{
  "machine_id": "${MACHINE_ID}",
  "provider": "${RUNNER_PLATFORM}",
  "gpu_name": "${RUNNER_GPU_NAME}",
  "gpu_count": ${NUM_GPUS},
  "gpu_vram": "${RUNNER_GPU_VRAM}",
  "instances": ${TOTAL_INSTANCES}
}
EOF
)

SESSION_RESPONSE=$(curl -s -S -X POST "${API_BASE_URL}/v1/worker/on" \
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

if [ -z "$WORKER_SESSION_ID" ]; then
    echo "[FATAL] Failed to obtain valid session ID from /v1/worker/on. Aborting to avoid unbilled runs."
    exit 1
fi
echo "[Billing] Active Worker Session ID: ${WORKER_SESSION_ID}"

# ==============================================================================
# 3. Storage Setup & Cleanup
# ==============================================================================
PERSISTENT_DIR="${PERSISTENT_STORAGE_DIR:-/workspace}"
MODEL_DIR="${PERSISTENT_DIR}/ComfyUI/models"

mkdir -p "${MODEL_DIR}/diffusion_models" \
         "${MODEL_DIR}/clip" \
         "${MODEL_DIR}/vae" \
         "${MODEL_DIR}/rife" \
         "${MODEL_DIR}/frame_interpolation" \
         "${PERSISTENT_DIR}/ComfyUI/input" \
         "${PERSISTENT_DIR}/ComfyUI/output"

rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

# Clear lock files, temp stats, and lingering WAL state
rm -f /tmp/worker_stats_*.json /tmp/worker_stats.json /tmp/comfy_pid_* /tmp/node_worker_pids.txt
rm -f /app/ComfyUI/user/comfyui.db* 2>/dev/null || true

# ==============================================================================
# 4. Model Weights Setup
# ==============================================================================
download_if_missing() {
    local target_dir="$1"
    local file_name="$2"
    local url="$3"

    mkdir -p "${target_dir}"
    if [ -f "${target_dir}/${file_name}" ]; then
        echo "[Storage] Found '${file_name}'. Skipping download."
        return 0
    fi

    echo "[Storage] Missing '${file_name}'. Downloading..."
    local ARIA_AUTH=()
    [ -n "$HF_TOKEN" ] && ARIA_AUTH=(--header="Authorization: Bearer ${HF_TOKEN}")

    if ! aria2c -x 8 -s 8 -k 1M --async-dns=false --max-tries=5 --retry-wait=2 \
        "${ARIA_AUTH[@]}" -d "${target_dir}" -o "${file_name}" "${url}"; then
        echo "[Storage Warning] aria2c failed. Retrying with wget..."
        if [ -n "$HF_TOKEN" ]; then
            wget --quiet --show-progress -c --header="Authorization: Bearer ${HF_TOKEN}" -O "${target_dir}/${file_name}" "${url}"
        else
            wget --quiet --show-progress -c -O "${target_dir}/${file_name}" "${url}"
        fi
    fi
}

RIFE_DIR="${MODEL_DIR}/rife"
FRAME_INTERP_DIR="${MODEL_DIR}/frame_interpolation"
download_if_missing "${RIFE_DIR}" "rife_v4.26_heavy.safetensors" "https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26_heavy.safetensors"

if [ -f "${RIFE_DIR}/rife_v4.26_heavy.safetensors" ] && [ ! -f "${FRAME_INTERP_DIR}/rife_v4.26_heavy.safetensors" ]; then
    ln -sf "${RIFE_DIR}/rife_v4.26_heavy.safetensors" "${FRAME_INTERP_DIR}/rife_v4.26_heavy.safetensors"
fi

# ==============================================================================
# 5. Spawning Backends and Workers
# ==============================================================================
pkill -f "main.py" || true
cd /app

export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

# Trap signals to ensure clean teardown
cleanup_processes() {
    echo "[Cleanup] Stopping child processes..."
    pkill -P $$ || true
    pkill -f "main.py" || true
    pkill -f "node worker.js" || true
}
trap cleanup_processes EXIT SIGINT SIGTERM

echo "[Startup] Spawning ComfyUI instances from plan..."
echo "$PLAN_JSON" | node -e '
const fs = require("fs");
const cp = require("child_process");
const logDir = process.env.LOG_DIR || "/var/log/runner";
const plan = JSON.parse(fs.readFileSync(0, "utf-8"));

plan.forEach(item => {
    console.log(`[Startup] Spawning ComfyUI instance ${item.instance} on GPU ${item.gpu} (Port ${item.port})`);
    const comfyEnv = Object.assign({}, process.env, { CUDA_VISIBLE_DEVICES: String(item.gpu) });
    const comfyLog = fs.openSync(`${logDir}/comfy_${item.instance}.log`, "a");
    const child = cp.spawn("/opt/venv/bin/python3", [
        "/app/ComfyUI/main.py",
        "--listen", "0.0.0.0",
        "--port", String(item.port),
        "--fast",
        "--use-sage-attention",
        "--disable-auto-launch"
    ], {
        env: comfyEnv,
        detached: true,
        stdio: ["ignore", comfyLog, comfyLog]
    });
    child.unref();
    fs.writeFileSync(`/tmp/comfy_pid_${item.instance}`, String(child.pid));
});
'

echo "[Startup] Waiting for all endpoints to pass health checks..."
PORTS=$(echo "$PLAN_JSON" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf8')).map(x => x.port).join(' '));")
for PORT in $PORTS; do
    echo "[HealthCheck] Polling port ${PORT}..."
    until curl -s "http://127.0.0.1:${PORT}/history" > /dev/null 2>&1; do
        sleep 1
    done
    echo "[HealthCheck] Port ${PORT} is UP."
done

echo "[Startup] Launching Node.js workers..."
WORKER_PIDS=()
for row in $(echo "$PLAN_JSON" | node -e "const fs=require('fs'); JSON.parse(fs.readFileSync(0,'utf8')).forEach(x => console.log(x.instance + ':' + x.port));"); do
    IDX="${row%%:*}"
    PORT="${row##*:}"
    echo "[Worker] Starting worker_${IDX} on port ${PORT}..."
    
    WORKER_SUFFIX="worker_${IDX}" \
    COMFY_PORT="${PORT}" \
    WORKER_SESSION_ID="${WORKER_SESSION_ID}" \
    node worker.js &
    
    WORKER_PIDS+=($!)
    echo $! >> /tmp/node_worker_pids.txt
done

echo "[Startup] All workers operational. Awaiting task loop exit..."

WORKER_EXIT_CODE=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" || WORKER_EXIT_CODE=$?
done

# ==============================================================================
# 6. Metrics Aggregation & Session Teardown
# ==============================================================================
UPTIME_SEC=$(( $(date +%s) - START_BOOT_TIME ))

if [ "$UPTIME_SEC" -lt 60 ] && [ "$WORKER_EXIT_CODE" -ne 0 ]; then
    echo "======================================================================"
    echo "[CRITICAL SAFETY GUARD] Worker failed within ${UPTIME_SEC}s (Exit code: ${WORKER_EXIT_CODE})!"
    echo "[CRITICAL SAFETY GUARD] Holding container active for 3600s for debugging."
    echo "======================================================================"
    sleep 3600
    exit 1
fi

echo "[Billing] Finalizing session with /v1/worker/off..."
STATS_DATA=$(node -e "
    const fs = require('fs');
    const path = require('path');
    let jobs = 0, duration = 0;
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

JOBS_PROCESSED=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf-8')).jobs || 0);")
TOTAL_GEN_TIME=$(echo "$STATS_DATA" | node -e "const fs=require('fs'); console.log(JSON.parse(fs.readFileSync(0,'utf-8')).duration || 0);")

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

# ==============================================================================
# 7. Auto-Termination
# ==============================================================================
if [ "$RUNNER_PLATFORM" = "lium" ] && [ -n "$LIUM_POD_ID" ]; then
    echo "[Teardown] Terminating Lium Pod: ${LIUM_POD_ID}"
    curl -s -X DELETE "${LIUM_BASE_URL:-https://lium.io/api}/pods/${LIUM_POD_ID}" \
        -H "X-API-Key: ${LIUM_API_KEY}" \
        -H "Accept: application/json" || true

elif [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
    echo "[Teardown] Hibernating Hyperstack VM..."
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
    [ -n "$VM_ID" ] && curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
        "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true

elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
    VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"
    if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
        curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
            -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"state": "stopped"}' || true
    fi
fi

exit $WORKER_EXIT_CODE