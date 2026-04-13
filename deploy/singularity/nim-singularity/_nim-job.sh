#!/bin/bash
#SBATCH --job-name=nim-llm
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --gres=gpu:4
#SBATCH --time=08:00:00
# -----------------------------------------------------------------------
# LLM SLURM Job Script (NIM and vLLM backends)
#
# This script runs ON the compute node allocated by SLURM.
# It is submitted by submit-nim-job.sh — do not run it directly.
#
# Backend is auto-detected from models.conf (nim or vllm).
# Both backends serve an OpenAI-compatible API on the same port.
#
# Environment variables expected (passed via --export=ALL):
#   NGC_API_KEY, NIM_BASE_DIR — mandatory
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
BACKEND_LABEL=$([ "$MODEL_BACKEND" = "vllm" ] && echo "vLLM" || echo "NIM")

cat > "$ENV_FILE" <<EOF
MODEL_KEY=$MODEL_KEY
MODEL_ID=$MODEL_ID
SIF_NAME=$SIF_NAME
MODEL_DESC=$MODEL_DESC
BACKEND=$MODEL_BACKEND
NODE=$(hostname)
PORT=$LLM_PORT
SLURM_JOB_ID=$SLURM_JOB_ID
USER=$USER
STARTED_AT=$(date -Iseconds)
ENDPOINT=http://$(hostname):$LLM_PORT
EOF

echo "=== LLM Job — $MODEL_DESC ($BACKEND_LABEL) ==="
echo ""
echo "Job ID:   $SLURM_JOB_ID"
echo "Node:     $(hostname)"
echo "Model:    $MODEL_KEY ($MODEL_ID)"
echo "Backend:  $BACKEND_LABEL"
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
# Launch inference server
# ==============================================================================
echo "Starting $BACKEND_LABEL server..."

if [ "$MODEL_BACKEND" = "vllm" ]; then
    # ==================================================================
    # vLLM backend — standalone vLLM serving with local HF weights
    # ==================================================================
    HF_MODEL_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
    if [ ! -d "$HF_MODEL_DIR" ] || [ -z "$(ls -A "$HF_MODEL_DIR" 2>/dev/null)" ]; then
        echo "ERROR: Model weights not found: $HF_MODEL_DIR"
        echo "Run: ./download-nim-model.sh $MODEL_KEY"
        exit 1
    fi
    echo "Weights:  $HF_MODEL_DIR"
    [ -n "$MODEL_EXTRA_ENV" ] && echo "Args:     $MODEL_EXTRA_ENV"

    # shellcheck disable=SC2086
    VLLM_CACHE="$JOB_DIR/vllm-cache"
    mkdir -p "$VLLM_CACHE"

    singularity exec \
        --nv \
        --writable-tmpfs \
        --contain \
        --workdir "$JOB_DIR/tmp" \
        --env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
        --env VLLM_CACHE_DIR=/vllm-cache \
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
else
    # ==================================================================
    # NIM backend — NVIDIA NIM with optional HF weight overlay
    # ==================================================================
    MODEL_CACHE="$NIM_MODELS_DIR/${MODEL_KEY}-cache"
    mkdir -p "$MODEL_CACHE"

    # Build per-model --env flags from models.conf extra_args column
    NIM_EXTRA_ENV=()
    if [ -n "$MODEL_EXTRA_ENV" ]; then
        NIM_EXTRA_ENV+=(--env "$MODEL_EXTRA_ENV")
        echo "Extra:    $MODEL_EXTRA_ENV"
    fi

    # Check for pre-downloaded HuggingFace weights (from download-nim-model.sh)
    HF_MODEL_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
    NIM_LOCAL_MODEL=()
    if [ -d "$HF_MODEL_DIR" ] && [ "$(ls -A "$HF_MODEL_DIR" 2>/dev/null)" ]; then
        # Overlay HF weights onto the NGC cache snapshot directory so NIM sees
        # them as already-downloaded NGC files.  This avoids NIM_MODEL_NAME
        # (which triggers auto-manifest generation with TP=1-only profiles)
        # and lets NIM use the baked-in manifest that has TP>1 profiles.
        NGC_BF16_SNAPS=("$MODEL_CACHE"/ngc/hub/models--*/snapshots/*-bf16)
        NGC_BF16_SNAP="${NGC_BF16_SNAPS[0]}"
        if [ ${#NGC_BF16_SNAPS[@]} -eq 1 ] && [ -d "$NGC_BF16_SNAP" ]; then
            CONTAINER_SNAP="/opt/nim/.cache${NGC_BF16_SNAP#"$MODEL_CACHE"}"
            echo "Using pre-downloaded weights: $HF_MODEL_DIR"
            echo "Overlaying on NGC cache: $CONTAINER_SNAP"
            NIM_LOCAL_MODEL+=(--bind "$HF_MODEL_DIR:$CONTAINER_SNAP")
            # Strip per-file checksums (HF/NGC metadata not byte-identical) and
            # workspace hash tags (recomputed from manifest content, breaks after edit).
            MANIFEST_NOCHECK="$JOB_DIR/model_manifest.yaml"
            singularity exec "$NIM_IMAGES_DIR/$SIF_NAME" \
                cat /opt/nim/etc/default/model_manifest.yaml \
                | sed -e '/^\s*checksum:/d' -e '/nim_workspace_hash_v1/d' > "$MANIFEST_NOCHECK"
            NIM_LOCAL_MODEL+=(--bind "$MANIFEST_NOCHECK:/opt/nim/etc/default/model_manifest.yaml")
        else
            echo "WARNING: NGC cache snapshot not found — falling back to NIM_MODEL_NAME"
            echo "  Run NIM once without local weights to create cache structure, then retry."
            NIM_LOCAL_MODEL+=(--bind "$HF_MODEL_DIR:/local-model")
            NIM_LOCAL_MODEL+=(--env "NIM_MODEL_NAME=/local-model")
            NIM_LOCAL_MODEL+=(--env "NIM_SERVED_MODEL_NAME=$MODEL_ID")
        fi
    fi

    singularity exec \
        --nv \
        --writable-tmpfs \
        --contain \
        --workdir "$JOB_DIR/tmp" \
        --env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
        --env NGC_API_KEY="$NGC_API_KEY" \
        --env NVIDIA_API_KEY="$NGC_API_KEY" \
        --cleanenv \
        --bind "$MODEL_CACHE:/opt/nim/.cache" \
        --env NIM_CACHE_PATH=/opt/nim/.cache \
        --env NIM_MAX_PARALLEL_DOWNLOADS=1 \
        --env NIM_LOG_LEVEL=INFO \
        --env OMPI_MCA_pmix=^all \
        --env OMPI_MCA_pml=ob1 \
        --env PMIX_MCA_gds=^ds12,ds21 \
        --env PMIX_MCA_psec=^munge \
        --env LD_PRELOAD="/usr/local/cuda/compat/lib.real/libcuda.so.1:/usr/local/cuda/compat/lib.real/libnvidia-ptxjitcompiler.so.1" \
        "${NIM_EXTRA_ENV[@]}" \
        "${NIM_LOCAL_MODEL[@]}" \
        "$NIM_IMAGES_DIR/$SIF_NAME" \
        /opt/nim/start_server.sh --tensor-parallel-size "$GPU_COUNT" \
        >> "$LOG_FILE" 2>&1 &

    HEALTH_URL="http://localhost:${LLM_PORT}/v1/health/ready"
fi

SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"
echo "$BACKEND_LABEL process started (PID $SERVER_PID)"

# ==============================================================================
# Cleanup on SIGTERM (scancel), SIGINT (Ctrl+C), or EXIT
# ==============================================================================
cleanup() {
    echo ""
    echo "[$(date -Iseconds)] Shutting down $BACKEND_LABEL (PID $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "[$(date -Iseconds)] $BACKEND_LABEL stopped."
}
trap cleanup SIGTERM SIGINT EXIT

# ==============================================================================
# Health check — wait for server to become ready
# ==============================================================================
sleep 3
if ! ps -p "$SERVER_PID" > /dev/null 2>&1; then
    echo ""
    echo "ERROR: $BACKEND_LABEL process died during startup."
    echo "Check log: $LOG_FILE"
    exit 1
fi

echo ""
echo "Waiting for $BACKEND_LABEL to become ready..."
echo "(First load can take 10-60+ min while model weights are loaded)"
echo ""

START_TIME=$(date +%s)

while true; do
    # Check if server process is still alive
    if ! ps -p "$SERVER_PID" > /dev/null 2>&1; then
        echo ""
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo "ERROR: $BACKEND_LABEL process died after $((ELAPSED/60))m$((ELAPSED%60))s."
        echo "Check log: $LOG_FILE"
        exit 1
    fi

    # Check health endpoint
    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        echo ""
        echo "============================================================"
        echo "$BACKEND_LABEL READY — $MODEL_DESC"
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
echo "$BACKEND_LABEL is serving. Waiting for termination signal..."
echo "(Stop with: scancel $SLURM_JOB_ID)"

# Disarm EXIT trap — we want cleanup only on signal, not on normal wait return.
# Re-arm for signals only.
trap - EXIT
trap cleanup SIGTERM SIGINT

wait "$SERVER_PID" 2>/dev/null || true
echo ""
echo "[$(date -Iseconds)] $BACKEND_LABEL process exited. Job complete."
