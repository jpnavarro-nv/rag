#!/bin/bash
# Start a LLM NIM on all 4x A100 GPUs (latency-optimized) and wait until ready.
# Self-contained: does not depend on 01-start-infrastructure.sh or config.sh.
#
# Usage:
#   export NGC_API_KEY="nvapi-..."
#   export NIM_BASE_DIR="/path/to/nim-workdir"
#
#   ./run-nim.sh                  # default: nemotron3-120b
#   ./run-nim.sh gpt-oss-120b    # select a specific model
#   ./run-nim.sh --list           # show available models
#
# All models run on 4x A100 80GB (CUDA_VISIBLE_DEVICES=0,1,2,3).
# NIM auto-selects the highest-TP latency profile for the available GPUs.

set -e

# ==============================================================================
# Model catalog
# ==============================================================================

show_models() {
    echo "Available models:"
    echo ""
    echo "  nemotron-49b     Nemotron Super 49B         (nvidia/llama-3.3-nemotron-super-49b-v1.5)"
    echo "  qwen3-122b       Qwen 3.5 122B-A10B MoE     (qwen/qwen3.5-122b-a10b)"
    echo "  gpt-oss-120b     GPT-OSS 120B MoE            (openai/gpt-oss-120b)"
    echo "  nemotron3-120b   Nemotron-3 Super 120B MoE   (nvidia/nemotron-3-super-120b-a12b)  [default]"
    echo ""
    echo "Example:"
    echo "  ./run-nim.sh gpt-oss-120b"
}

resolve_model() {
    case "$1" in
        nemotron-49b)
            SIF_NAME="nim-llm-nemotron-49b.sif"
            MODEL_API="nvidia/llama-3.3-nemotron-super-49b-v1.5"
            MODEL_DESC="Nemotron Super 49B"
            ;;
        qwen3-122b)
            SIF_NAME="nim-llm-qwen3-122b.sif"
            MODEL_API="qwen/qwen3.5-122b-a10b"
            MODEL_DESC="Qwen 3.5 122B-A10B"
            ;;
        gpt-oss-120b)
            SIF_NAME="nim-llm-gpt-oss-120b.sif"
            MODEL_API="openai/gpt-oss-120b"
            MODEL_DESC="GPT-OSS 120B"
            ;;
        nemotron3-120b)
            SIF_NAME="nim-llm-nemotron3-120b.sif"
            MODEL_API="nvidia/nemotron-3-super-120b-a12b"
            MODEL_DESC="Nemotron-3 Super 120B-A12B"
            ;;
        *)
            echo "Unknown model: $1"
            echo ""
            show_models
            exit 1
            ;;
    esac
}

# ==============================================================================
# Argument handling
# ==============================================================================
case "${1:-}" in
    --list|-l)
        show_models
        exit 0
        ;;
    --help|-h)
        echo "Usage: ./run-nim.sh [MODEL]"
        echo ""
        show_models
        exit 0
        ;;
esac

MODEL_KEY="${1:-nemotron3-120b}"
resolve_model "$MODEL_KEY"

# ==============================================================================
# Required environment
# ==============================================================================
export NIM_BASE_DIR="${NIM_BASE_DIR:?Set NIM_BASE_DIR before running}"
if [ -z "$NGC_API_KEY" ]; then
    echo "NGC_API_KEY not set. Export it before running:"
    echo "   export NGC_API_KEY='nvapi-...'"
    exit 1
fi

# ==============================================================================
# Configuration
# ==============================================================================
LLM_PORT=${LLM_PORT:-8999}
LLM_GPU_ID=${LLM_GPU_ID:-0,1,2,3}       # all 4x A100 80GB
CHECK_INTERVAL=${CHECK_INTERVAL:-5}

# ==============================================================================
# Directory layout (self-contained)
# ==============================================================================
NIM_IMAGES_DIR="$NIM_BASE_DIR/containers/images"
NIM_LLM_CACHE_DIR="$NIM_BASE_DIR/models/${MODEL_KEY}-cache"
export SINGULARITY_TMPDIR=/tmp

SESSION_DIR="$NIM_BASE_DIR/llm-session"
LOG_DIR="$SESSION_DIR/logs"
PID_DIR="$SESSION_DIR/pids"

mkdir -p "$NIM_LLM_CACHE_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$PID_DIR"

SIF="$NIM_IMAGES_DIR/$SIF_NAME"
PID_FILE="$PID_DIR/nim-llm.pid"
LOG_FILE="$LOG_DIR/${MODEL_KEY}.log"

# ==============================================================================
# Pre-flight checks
# ==============================================================================
if [ ! -f "$SIF" ]; then
    echo "Image not found: $SIF"
    echo "   Run ./build-nim-images.sh first."
    exit 1
fi

# Check if already running
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE")
    if ps -p "$EXISTING_PID" > /dev/null 2>&1; then
        RUNNING_MODEL=$(cat "$PID_DIR/nim-llm.model" 2>/dev/null || echo "unknown")
        echo "LLM NIM already running (PID $EXISTING_PID, model: $RUNNING_MODEL)"
        echo "   Kill first: kill $EXISTING_PID"
        exit 1
    fi
    rm -f "$PID_FILE" "$PID_DIR/nim-llm.model"
fi

# ==============================================================================
# Cleanup on exit (Ctrl+C or error during startup/wait)
# ==============================================================================
cleanup() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo ""
            echo "Stopping LLM NIM (PID $pid)..."
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE" "$PID_DIR/nim-llm.model"
    fi
}
trap cleanup EXIT

# ==============================================================================
# Launch LLM NIM
# ==============================================================================
echo "=== LLM NIM — $MODEL_DESC ==="
echo ""
echo "Model:        $MODEL_KEY ($MODEL_API)"
echo "NIM_BASE_DIR: $NIM_BASE_DIR"
echo "Image:        $SIF"
echo "Port:         $LLM_PORT"
echo "GPUs:         $LLM_GPU_ID (4x A100 — latency-optimized)"
echo "Cache:        $NIM_LLM_CACHE_DIR"
echo "Log:          $LOG_FILE"
echo ""
echo "Starting..."

> "$LOG_FILE"

# NIM auto-selection with 4 visible GPUs prefers the highest-TP latency profile.
# NIM_SCHEDULER_POLICY=guarantee_no_evict further optimizes for latency (lower
# TTFT/ITL) by avoiding request eviction under memory pressure.
singularity exec \
    --nv \
    --cleanenv \
    --env CUDA_VISIBLE_DEVICES="$LLM_GPU_ID" \
    --env NGC_API_KEY="$NGC_API_KEY" \
    --env NVIDIA_API_KEY="$NGC_API_KEY" \
    --env NIM_CACHE_PATH=/opt/nim/.cache \
    --env NIM_SCHEDULER_POLICY=guarantee_no_evict \
    --env OMPI_MCA_pmix=^all \
    --env OMPI_MCA_pml=ob1 \
    --env PMIX_MCA_gds=^ds12,ds21 \
    --env PMIX_MCA_psec=^munge \
    --bind "$NIM_LLM_CACHE_DIR:/opt/nim/.cache" \
    "$SIF" \
    /opt/nim/start_server.sh --port "$LLM_PORT" \
    >> "$LOG_FILE" 2>&1 &

NIM_PID=$!
echo "$NIM_PID" > "$PID_FILE"
echo "$MODEL_KEY" > "$PID_DIR/nim-llm.model"

sleep 3
if ! ps -p "$NIM_PID" > /dev/null 2>&1; then
    echo "LLM NIM failed to start. Check log:"
    echo "   tail -30 $LOG_FILE"
    rm -f "$PID_FILE" "$PID_DIR/nim-llm.model"
    exit 1
fi

echo "LLM NIM started (PID $NIM_PID)"
echo ""

# ==============================================================================
# Wait for health
# ==============================================================================
echo "Waiting for $MODEL_DESC to become ready..."
echo "   (first load can take 10-60 min while weights are downloaded)"
echo "   Health endpoint: http://localhost:$LLM_PORT/v1/health/ready"
echo ""

START_TIME=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    MINS=$((ELAPSED / 60))
    SECS=$((ELAPSED % 60))

    # Check if process is still alive
    if ! ps -p "$NIM_PID" > /dev/null 2>&1; then
        echo ""
        echo "LLM NIM process died after ${MINS}m${SECS}s"
        echo "   Check log: tail -50 $LOG_FILE"
        rm -f "$PID_FILE" "$PID_DIR/nim-llm.model"
        exit 1
    fi

    # Check health
    if curl -s -f "http://localhost:${LLM_PORT}/v1/health/ready" > /dev/null 2>&1; then
        echo ""
        echo "LLM NIM ready after ${MINS}m${SECS}s"
        echo ""
        echo "=== $MODEL_DESC is serving ==="
        echo "   Model:    $MODEL_API"
        echo "   Endpoint: http://localhost:$LLM_PORT"
        echo "   Health:   http://localhost:$LLM_PORT/v1/health/ready"
        echo "   Models:   http://localhost:$LLM_PORT/v1/models"
        echo "   Log:      $LOG_FILE"
        echo "   PID:      $NIM_PID"
        echo ""
        echo "Test:"
        echo "   python run_inference.py \"Hello, who are you?\""
        echo ""
        echo "Stop:"
        echo "   kill $NIM_PID"

        # Disarm cleanup trap — NIM should keep running after script exits
        trap - EXIT
        exit 0
    fi

    printf "\r   Loading... %dm%02ds" "$MINS" "$SECS"
    sleep "$CHECK_INTERVAL"
done
