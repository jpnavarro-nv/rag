#!/bin/bash
#SBATCH --job-name=nim-llm
#SBATCH --nodes=1
# -----------------------------------------------------------------------
# LLM SLURM Job Script (vLLM backend)
#
# This script runs ON the compute node allocated by SLURM.
# It is submitted by submit-nim-job.sh — do not run it directly.
#
# Serves an OpenAI-compatible API via vLLM with pre-downloaded HF weights.
#
# Environment variables expected (passed via --export=ALL):
#   NIM_BASE_DIR — mandatory
#   CHECK_INTERVAL — optional (default: 15s)
# -----------------------------------------------------------------------

set -euo pipefail

MODEL_KEY="${1:?ERROR: MODEL_KEY argument required}"

# NIM_SCRIPT_DIR is exported by submit-nim-job.sh and passed via --export=ALL.
# We cannot use BASH_SOURCE here because SLURM copies the job script to
# /var/spool/slurmd/job<ID>/ on the compute node — away from the other files.
SCRIPT_DIR="${NIM_SCRIPT_DIR:?ERROR: NIM_SCRIPT_DIR not set (submit via submit-nim-job.sh)}"

# ==============================================================================
# Source configuration (paths, resolve_model, defaults)
# ==============================================================================
source "$SCRIPT_DIR/nim-config.sh"
resolve_model "$MODEL_KEY"

# ==============================================================================
# Create per-job directory
# ==============================================================================
JOB_DIR="$NIM_SESSIONS_DIR/$USER/job_$SLURM_JOB_ID"
mkdir -p "$JOB_DIR/tmp"

# Symlink SLURM output (written to flat path by sbatch) into the job directory
SLURM_OUT="$NIM_SESSIONS_DIR/$USER/nim-${SLURM_JOB_ID}.out"
if [ -f "$SLURM_OUT" ]; then
    ln -sf "$SLURM_OUT" "$JOB_DIR/slurm.out"
fi

LOG_FILE="$JOB_DIR/nim.log"
PID_FILE="$JOB_DIR/nim.pid"
ENV_FILE="$JOB_DIR/nim.env"

# ==============================================================================
# Write job metadata (sourceable by other scripts)
# ==============================================================================
cat > "$ENV_FILE" <<EOF
MODEL_KEY="$MODEL_KEY"
MODEL_ID="$MODEL_ID"
SIF_NAME="$SIF_NAME"
MODEL_DESC="$MODEL_DESC"
BACKEND="vllm"
NODE="$(hostname)"
PORT="$LLM_PORT"
SLURM_JOB_ID="$SLURM_JOB_ID"
USER="$USER"
STARTED_AT="$(date -Iseconds)"
ENDPOINT="http://$(hostname):$LLM_PORT"
EOF

echo "=== LLM Job — $MODEL_DESC (vLLM) ==="
echo ""
echo "Job ID:   $SLURM_JOB_ID"
echo "Node:     $(hostname)"
echo "Model:    $MODEL_KEY ($MODEL_ID)"
echo "Backend:  vLLM"
echo "SIF:      $NIM_IMAGES_DIR/$SIF_NAME"
echo "Port:     $LLM_PORT"
echo "GPUs:     $CUDA_VISIBLE_DEVICES"
echo "Log:      $LOG_FILE"
echo "Metadata: $ENV_FILE"
echo ""

# ==============================================================================
# Compute GPU count from SLURM allocation for tensor parallelism
# ==============================================================================
GPU_COUNT=$(echo "$CUDA_VISIBLE_DEVICES" | tr ',' '\n' | wc -l)

# ==============================================================================
# Launch vLLM inference server
# ==============================================================================
echo "Starting vLLM server..."

HF_MODEL_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
if [ ! -d "$HF_MODEL_DIR" ] || [ -z "$(ls -A "$HF_MODEL_DIR" 2>/dev/null)" ]; then
    echo "ERROR: Model weights not found: $HF_MODEL_DIR"
    echo "Run: ./download-nim-model.sh $MODEL_KEY"
    exit 1
fi
echo "Weights:  $HF_MODEL_DIR"
[ -n "$MODEL_EXTRA_ENV" ] && echo "Args:     $MODEL_EXTRA_ENV"

VLLM_CACHE="$JOB_DIR/vllm-cache"
mkdir -p "$VLLM_CACHE"

# CUDA forward compatibility: if the container's CUDA version is newer
# than the host driver's native CUDA, LD_PRELOAD the compat libs so they
# override the older host libcuda.so injected by --nv.
VLLM_PRELOAD=()
CUDA_COMPAT_LIB=$(singularity exec "$NIM_IMAGES_DIR/$SIF_NAME" \
    bash -c 'ls /usr/local/cuda-*/compat/libcuda.so.1 2>/dev/null | head -1')
if [ -n "$CUDA_COMPAT_LIB" ]; then
    COMPAT_DIR=$(dirname "$CUDA_COMPAT_LIB")
    CONTAINER_CUDA=$(echo "$COMPAT_DIR" | sed 's|.*/cuda-\([0-9.]*\)/compat|\1|')
    HOST_CUDA=$(nvidia-smi 2>/dev/null | grep "CUDA Version" | awk '{print $9}')
    if [ -n "$HOST_CUDA" ] && [ "$(printf '%s\n' "$HOST_CUDA" "$CONTAINER_CUDA" | sort -V | tail -1)" != "$HOST_CUDA" ]; then
        VLLM_PRELOAD=(--env LD_PRELOAD="$COMPAT_DIR/libcuda.so.1:$COMPAT_DIR/libnvidia-ptxjitcompiler.so.1")
        echo "CUDA compat: container=$CONTAINER_CUDA > host=$HOST_CUDA (LD_PRELOAD enabled)"
    else
        echo "CUDA compat: not needed (container=$CONTAINER_CUDA, host=$HOST_CUDA)"
    fi
fi

# shellcheck disable=SC2086
singularity exec \
    --nv \
    --writable-tmpfs \
    --contain \
    --workdir "$JOB_DIR/tmp" \
    --env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    --env VLLM_CACHE_DIR=/vllm-cache \
    "${VLLM_PRELOAD[@]}" \
    --bind "$VLLM_CACHE:/vllm-cache" \
    --bind "$HF_MODEL_DIR:/model" \
    "$NIM_IMAGES_DIR/$SIF_NAME" \
    python3 -m vllm.entrypoints.openai.api_server \
        --model /model \
        --tensor-parallel-size "$GPU_COUNT" \
        --port "$LLM_PORT" \
        --trust-remote-code \
        $MODEL_EXTRA_ENV \
    >> "$LOG_FILE" 2>&1 &

HEALTH_URL="http://localhost:${LLM_PORT}/health"

SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"
echo "vLLM process started (PID $SERVER_PID)"

# ==============================================================================
# Cleanup on SIGTERM (scancel), SIGINT (Ctrl+C), or EXIT
# ==============================================================================
cleanup() {
    echo ""
    echo "[$(date -Iseconds)] Shutting down vLLM (PID $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "[$(date -Iseconds)] vLLM stopped."
}
trap cleanup SIGTERM SIGINT EXIT

# ==============================================================================
# Health check — wait for server to become ready
# ==============================================================================
sleep 3
if ! ps -p "$SERVER_PID" > /dev/null 2>&1; then
    echo ""
    echo "ERROR: vLLM process died during startup."
    echo "Check log: $LOG_FILE"
    exit 1
fi

echo ""
echo "Waiting for vLLM to become ready..."
echo "(First load can take 10-60+ min while model weights are loaded)"
echo ""

START_TIME=$(date +%s)

while true; do
    # Check if server process is still alive
    if ! ps -p "$SERVER_PID" > /dev/null 2>&1; then
        echo ""
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo "ERROR: vLLM process died after $((ELAPSED/60))m$((ELAPSED%60))s."
        echo "Check log: $LOG_FILE"
        exit 1
    fi

    # Check health endpoint
    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo ""
        echo "============================================================"
        echo "vLLM READY — $MODEL_DESC"
        echo "============================================================"
        echo "  Endpoint: http://$(hostname):$LLM_PORT"
        echo "  Model:    $MODEL_ID"
        echo "  Job ID:   $SLURM_JOB_ID"
        echo "  Node:     $(hostname)"
        echo "  Ready in: $((ELAPSED/60))m$((ELAPSED%60))s"
        echo ""
        echo "  Test:"
        echo "    python scripts/run_inference.py --url http://$(hostname):$LLM_PORT \"Hello\""
        echo ""
        echo "  Stop:"
        echo "    scancel $SLURM_JOB_ID"
        echo "============================================================"
        break
    fi

    ELAPSED=$(( $(date +%s) - START_TIME ))
    printf "\r  Loading... %dm%02ds" $((ELAPSED/60)) $((ELAPSED%60))
    sleep "$CHECK_INTERVAL"
done

# ==============================================================================
# Block until server exits or job is cancelled
# ==============================================================================
echo ""
echo "vLLM is serving. Waiting for termination signal..."
echo "(Stop with: scancel $SLURM_JOB_ID)"

# Disarm EXIT trap — we want cleanup only on signal, not on normal wait return.
# Re-arm for signals only.
trap - EXIT
trap cleanup SIGTERM SIGINT

wait "$SERVER_PID" 2>/dev/null || true
echo ""
echo "[$(date -Iseconds)] vLLM process exited. Job complete."
