#!/bin/bash
#SBATCH --job-name=nim-llm
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:4
#SBATCH --time=08:00:00
# -----------------------------------------------------------------------
# NIM LLM SLURM Job Script
#
# This script runs ON the compute node allocated by SLURM.
# It is submitted by submit-nim-job.sh — do not run it directly.
#
# Environment variables expected (passed via --export=ALL):
#   NGC_API_KEY, NIM_BASE_DIR — mandatory
#   LLM_PORT, CHECK_INTERVAL — optional (have defaults)
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
MODEL_KEY=$MODEL_KEY
MODEL_ID=$MODEL_ID
SIF_NAME=$SIF_NAME
MODEL_DESC=$MODEL_DESC
NODE=$(hostname)
PORT=$LLM_PORT
SLURM_JOB_ID=$SLURM_JOB_ID
USER=$USER
STARTED_AT=$(date -Iseconds)
ENDPOINT=http://$(hostname):$LLM_PORT
EOF

echo "=== NIM LLM Job — $MODEL_DESC ==="
echo ""
echo "Job ID:   $SLURM_JOB_ID"
echo "Node:     $(hostname)"
echo "Model:    $MODEL_KEY ($MODEL_ID)"
echo "SIF:      $NIM_IMAGES_DIR/$SIF_NAME"
echo "Port:     $LLM_PORT"
echo "GPUs:     $CUDA_VISIBLE_DEVICES"
echo "Log:      $LOG_FILE"
echo "Metadata: $ENV_FILE"
echo ""

# ==============================================================================
# Model cache (shared — downloaded once, read by all jobs)
# ==============================================================================
MODEL_CACHE="$NIM_MODELS_DIR/${MODEL_KEY}-cache"
mkdir -p "$MODEL_CACHE"

# ==============================================================================
# Launch NIM
# ==============================================================================
echo "Starting NIM server..."

# Build per-model --env flags from models.conf extra_env column
NIM_EXTRA_ENV=()
if [ -n "$MODEL_EXTRA_ENV" ]; then
    NIM_EXTRA_ENV+=(--env "$MODEL_EXTRA_ENV")
    echo "Extra:    $MODEL_EXTRA_ENV"
fi

singularity exec \
    --nv \
    --writable-tmpfs \
    --env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    --env NGC_API_KEY="$NGC_API_KEY" \
    --env NVIDIA_API_KEY="$NGC_API_KEY" \
    --cleanenv \
    --bind "$MODEL_CACHE:/opt/nim/.cache" \
    --env NIM_CACHE_PATH=/opt/nim/.cache \
    --env NIM_LOG_LEVEL=INFO \
    --env OMPI_MCA_pmix=^all \
    --env OMPI_MCA_pml=ob1 \
    --env PMIX_MCA_gds=^ds12,ds21 \
    --env PMIX_MCA_psec=^munge \
    "${NIM_EXTRA_ENV[@]}" \
    "$NIM_IMAGES_DIR/$SIF_NAME" \
    /opt/nim/start_server.sh --port "$LLM_PORT" \
    >> "$LOG_FILE" 2>&1 &

NIM_PID=$!
echo "$NIM_PID" > "$PID_FILE"
echo "NIM process started (PID $NIM_PID)"

# ==============================================================================
# Cleanup on SIGTERM (scancel), SIGINT (Ctrl+C), or EXIT
# ==============================================================================
cleanup() {
    echo ""
    echo "[$(date -Iseconds)] Shutting down NIM (PID $NIM_PID)..."
    kill "$NIM_PID" 2>/dev/null || true
    wait "$NIM_PID" 2>/dev/null || true
    echo "[$(date -Iseconds)] NIM stopped."
}
trap cleanup SIGTERM SIGINT EXIT

# ==============================================================================
# Health check — wait for NIM to become ready
# ==============================================================================
sleep 3
if ! ps -p "$NIM_PID" > /dev/null 2>&1; then
    echo ""
    echo "ERROR: NIM process died during startup."
    echo "Check log: $LOG_FILE"
    exit 1
fi

echo ""
echo "Waiting for NIM to become ready..."
echo "(First load can take 10-60+ min while model weights are downloaded)"
echo ""

START_TIME=$(date +%s)

while true; do
    # Check if NIM process is still alive
    if ! ps -p "$NIM_PID" > /dev/null 2>&1; then
        echo ""
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo "ERROR: NIM process died after $((ELAPSED/60))m$((ELAPSED%60))s."
        echo "Check log: $LOG_FILE"
        exit 1
    fi

    # Check health endpoint
    if curl -sf "http://localhost:${LLM_PORT}/v1/health/ready" > /dev/null 2>&1; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo ""
        echo "============================================================"
        echo "NIM READY — $MODEL_DESC"
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
# Block until NIM exits or job is cancelled
# ==============================================================================
echo ""
echo "NIM is serving. Waiting for termination signal..."
echo "(Stop with: scancel $SLURM_JOB_ID)"

# Disarm EXIT trap — we want cleanup only on signal, not on normal wait return.
# Re-arm for signals only.
trap - EXIT
trap cleanup SIGTERM SIGINT

wait "$NIM_PID" 2>/dev/null || true
echo ""
echo "[$(date -Iseconds)] NIM process exited. Job complete."
