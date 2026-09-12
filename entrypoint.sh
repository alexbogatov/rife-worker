#!/bin/bash
set -eo pipefail

START_BOOT_TIME=$(date +%s)
export GIT_TERMINAL_PROMPT=0

# ==============================================================================
# Global Logging & Initialization
# ==============================================================================
LOG_DIR="${LOG_DIR:-/var/log/runner}"
mkdir -p "${LOG_DIR}"

# Mirror all stdout/stderr directly to terminal (Docker stdout) and entrypoint.log
exec > >(tee -a "${LOG_DIR}/entrypoint.log") 2>&1

echo "===================================================="
echo "[Startup] Bootstrapping Multi-GPU ComfyUI Pipeline"
echo "===================================================="

# Diagnostic check: verify worker.js is actually JavaScript
echo "[Diagnostic] Checking /app/worker.js head:"
head -n 3 /app/worker.js || true
if head -n 3 /app/worker.js | grep -qi "pipefail\|bash\|bin"; then
    echo "[CRITICAL ERROR] /app/worker.js contains shell script code! Aborting."
    sleep 3600
    exit 1
fi

# ==============================================================================
# 1. Platform & GPU Auto-Discovery
# ==============================================================================

discover_lium_pod_id() {
    if [ -z "$LIUM_API_KEY" ]; then
        return 1
    fi

    local lium_base="${LIUM_BASE_URL:-https://lium.io/api}"

    python3 -c '
import json, urllib.request, socket, sys

api_key = sys.argv[1]
base_url = sys.argv[2]
host = socket.gethostname().strip().lower()

req = urllib.request.Request(f"{base_url}/pods", headers={"X-API-Key": api_key, "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode())
        pods = data if isinstance(data, list) else data.get("data", data.get("pods", []))
        if not pods:
            sys.exit(1)

        match = None
        for p in pods:
            containers = p.get("executor", {}).get("specs", {}).get("docker", {}).get("containers", [])
            if any(c.get("container_id", "").lower().startswith(host) for c in containers):
                match = p
                break

        if not match and len(pods) == 1:
            match = pods[0]

        if match:
            pod_id = match.get("id") or match.get("uuid") or match.get("pod_id")
            if pod_id:
                sys.stdout.write(str(pod_id))
                sys.exit(0)
except Exception:
    pass

sys.exit(1)
' "$LIUM_API_KEY" "$lium_base"
}

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
if [ "$NUM_GPUS" -lt 1 ]; then
    NUM_GPUS=1
fi

# ==============================================================================
# Per-GPU Dynamic Scaling (Strictly math.floor(VRAM / 15GB), ignoring INSTANCES)
# ==============================================================================
CALC_METRICS=$(node -e '
const cp = require("child_process");
let vramList = [49152];
try {
    const smi = cp.execSync("nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits", {encoding: "utf8"});
    vramList = smi.trim().split("\n").map(x => parseInt(x.trim())).filter(x => !isNaN(x));
} catch(e) {}

let totalInstances = 0;
vramList.forEach(vram => {
    let workers = Math.floor(vram / 15360);
    if (workers < 1) workers = 1;
    totalInstances += workers;
});
console.log(totalInstances);
')

TOTAL_INSTANCES="${CALC_METRICS:-1}"

MACHINE_ID=$(hostname)
API_BASE_URL="${API_BASE_URL:-https://api.runltx.com}"
HYPERSTACK_VM_NAME="${VM_NAME:-${MACHINE_ID}}"

echo "===================================================="
echo "[Platform] Runtime  : $RUNNER_PLATFORM"
echo "[Hardware] GPU Model: $RUNNER_GPU_NAME ($NUM_GPUS detected)"
echo "[Hardware] Scaling  : Per-GPU math.floor(VRAM/15GB) -> ${TOTAL_INSTANCES} total worker(s)"
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
  "gpu_count": ${NUM_GPUS},
  "gpu_vram": "${RUNNER_GPU_VRAM}",
  "instances": ${TOTAL_INSTANCES}
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
         "${MODEL_DIR}/rife" \
         "${MODEL_DIR}/frame_interpolation" \
         "${PERSISTENT_DIR}/ComfyUI/input" \
         "${PERSISTENT_DIR}/ComfyUI/output"

rm -rf /app/ComfyUI/models /app/ComfyUI/input /app/ComfyUI/output
ln -sfn "${MODEL_DIR}" /app/ComfyUI/models
ln -sfn "${PERSISTENT_DIR}/ComfyUI/input" /app/ComfyUI/input
ln -sfn "${PERSISTENT_DIR}/ComfyUI/output" /app/ComfyUI/output

rm -f /tmp/worker_stats_*.json /tmp/worker_stats.json /tmp/comfy_pid_* /tmp/node_worker_pids.txt

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
        echo "[Storage] Missing '${file_name}'. Downloading..."
        local ARIA_AUTH=()
        if [ -n "$HF_TOKEN" ]; then
            ARIA_AUTH=(--header="Authorization: Bearer ${HF_TOKEN}")
        fi

        if ! aria2c -x 8 -s 8 -k 1M --async-dns=false --max-tries=5 --retry-wait=2 \
            "${ARIA_AUTH[@]}" -d "${target_dir}" -o "${file_name}" "${url}"; then
            echo "[Storage Warning] aria2c failed. Falling back to wget..."
            if [ -n "$HF_TOKEN" ]; then
                wget --quiet --show-progress -c --header="Authorization: Bearer ${HF_TOKEN}" -O "${target_dir}/${file_name}" "${url}"
            else
                wget --quiet --show-progress -c -O "${target_dir}/${file_name}" "${url}"
            fi
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
# 5. Launch Parallel ComfyUI Instances & Workers per GPU
# ==============================================================================
pkill -f "main.py" || true
rm -f /app/ComfyUI/user/comfyui.db.lock || true
cd /app

export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

BASE_PORT=8188

echo "[Startup] Spawning ComfyUI instances mapped per GPU..."

node -e '
const fs = require("fs");
const cp = require("child_process");

let vramList = [49152];
try {
    const smi = cp.execSync("nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits", {encoding: "utf8"});
    vramList = smi.trim().split("\n").map(x => parseInt(x.trim())).filter(x => !isNaN(x));
} catch(e) {}

let globalIdx = 1;
const basePort = 8188;
const logDir = process.env.LOG_DIR || "/var/log/runner";

vramList.forEach((vram, gpuIdx) => {
    const workers = Math.max(1, Math.floor(vram / 15360));
    console.log(`[Startup] GPU ${gpuIdx} (${vram} MiB VRAM): assigning ${workers} instance(s)`);
    for (let w = 0; w < workers; w++) {
        const port = basePort + globalIdx - 1;
        
        console.log(`[Startup] Spawning ComfyUI instance ${globalIdx} on GPU ${gpuIdx} (Port ${port})`);
        const comfyEnv = Object.assign({}, process.env, { CUDA_VISIBLE_DEVICES: String(gpuIdx) });
        const comfyLog = fs.openSync(`${logDir}/comfy_${globalIdx}.log`, "a");
        const comfyChild = cp.spawn("/opt/venv/bin/python3", [
            "/app/ComfyUI/main.py",
            "--listen", "0.0.0.0",
            "--port", String(port),
            "--fast",
            "--use-sage-attention",
            "--disable-auto-launch"
        ], {
            env: comfyEnv,
            detached: true,
            stdio: ["ignore", comfyLog, comfyLog]
        });
        fs.writeFileSync(`/tmp/comfy_pid_${globalIdx}`, String(comfyChild.pid));
        globalIdx++;
    }
});
'

echo "[Startup] Waiting for all ${TOTAL_INSTANCES} ComfyUI endpoint(s) to respond..."
for i in $(seq 1 "$TOTAL_INSTANCES"); do
    PORT=$((BASE_PORT + i - 1))
    until curl -s "http://127.0.0.1:${PORT}/history" > /dev/null 2>&1; do
        sleep 1
    done
done
echo "[Startup] All ComfyUI endpoints are healthy."

echo "[Startup] Launching ${TOTAL_INSTANCES} Node.js workers..."
WORKER_PIDS=()
for i in $(seq 1 "$TOTAL_INSTANCES"); do
    PORT=$((BASE_PORT + i - 1))
    WORKER_SESSION_ID="${WORKER_SESSION_ID}" COMFY_PORT="${PORT}" WORKER_SUFFIX="worker_${i}" node worker.js > >(tee -a "${LOG_DIR}/worker_${i}.log") 2>&1 &
    WORKER_PIDS+=($!)
    echo $! >> /tmp/node_worker_pids.txt
done

echo "[Startup] All workers operational. Streaming active logs..."

# Await workers completion
WORKER_EXIT_CODE=0
for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" || WORKER_EXIT_CODE=$?
done

# Teardown ComfyUI instances using saved PIDs
if [ -f /tmp/comfy_pid_1 ]; then
    for i in $(seq 1 "$TOTAL_INSTANCES"); do
        if [ -f "/tmp/comfy_pid_${i}" ]; then
            kill -9 "$(cat /tmp/comfy_pid_${i})" 2>/dev/null || true
        fi
    done
fi
pkill -f "main.py" || true

# ==============================================================================
# 6. Session Teardown Guard & Aggregation
# ==============================================================================
UPTIME_SEC=$(( $(date +%s) - START_BOOT_TIME ))

# Guard against self-destruction on early boot failure
if [ "$UPTIME_SEC" -lt 60 ] && [ "$WORKER_EXIT_CODE" -ne 0 ]; then
    echo "======================================================================"
    echo "[CRITICAL SAFETY GUARD] Workers failed within ${UPTIME_SEC}s of startup!"
    echo "[CRITICAL SAFETY GUARD] Exit Code: ${WORKER_EXIT_CODE}. Preventing instant VM destruction."
    echo "[CRITICAL SAFETY GUARD] Sleeping for 3600s so you can inspect the issue."
    echo "======================================================================"
    sleep 3600
    exit 1
fi

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

# ==============================================================================
# 7. Cloud Self-Termination
# ==============================================================================

if [ "$RUNNER_PLATFORM" = "lium" ] && [ -n "$LIUM_POD_ID" ]; then
    echo "[Teardown] Calling Lium DELETE /api/pods/${LIUM_POD_ID}..."
    LIUM_BASE_URL="${LIUM_BASE_URL:-https://lium.io/api}"
    curl -s -X DELETE "${LIUM_BASE_URL}/pods/${LIUM_POD_ID}" \
        -H "X-API-Key: ${LIUM_API_KEY}" \
        -H "Accept: application/json" || true

elif [ "$RUNNER_PLATFORM" = "hyperstack" ] && [ -n "$HYPERSTACK_API_KEY" ]; then
    echo "[Teardown] Requesting Hyperstack VM Hibernation..."
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
        curl -s -H "api_key: ${HYPERSTACK_API_KEY}" \
            "${HYPERSTACK_API_URL}/core/virtual-machines/${VM_ID}/hibernate?retain_ip=true" || true
    fi

elif [ "$RUNNER_PLATFORM" = "vastai" ]; then
    VAST_ID="${CONTAINER_ID:-${VAST_CONTAINERLABEL:-${MACHINE_ID}}}"
    if [ -n "$CONTAINER_API_KEY" ] && [ -n "$VAST_ID" ]; then
        curl -s -X PUT "https://console.vast.ai/api/v0/instances/${VAST_ID}/" \
            -H "Authorization: Bearer ${CONTAINER_API_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"state": "stopped"}' || true
    else
        kill -s TERM 1 2>/dev/null || true
    fi
fi

exit $WORKER_EXIT_CODE