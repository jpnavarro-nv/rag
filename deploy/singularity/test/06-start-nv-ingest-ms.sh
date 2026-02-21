#!/bin/bash
# Start NV-Ingest Microservice Runtime
# Run after 03-start-redis.sh and 05-wait-nim-models.sh
#
# NV-Ingest is the engine that processes documents using Ray and the NIM models

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

NVINGEST_PORT=${NVINGEST_PORT:-7670}
NVINGEST_BROKER_PORT=${NVINGEST_BROKER_PORT:-7671}
NVINGEST_HOST=${NVINGEST_HOST:-localhost}
# GPU 3: Vision & Ingestion (paired with VLM which NV-Ingest calls for captioning)
NVINGEST_GPU_ID=${NVINGEST_GPU_ID:-3}

# Redis configuration
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}

# NIM endpoints (from previous script)
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
VLM_PORT=${VLM_PORT:-1977}
PAGE_ELEMENTS_PORT=${PAGE_ELEMENTS_PORT:-8000}
GRAPHIC_ELEMENTS_PORT=${GRAPHIC_ELEMENTS_PORT:-8003}
TABLE_STRUCTURE_PORT=${TABLE_STRUCTURE_PORT:-8016}
PADDLE_OCR_PORT=${PADDLE_OCR_PORT:-8009}

# ==============================================================================
# Healthcheck Function
# ==============================================================================

wait_for_nvingest() {
    local host=$1
    local port=$2
    local pid=$3
    local start
    start=$(date +%s)

    echo "   ⏳ Waiting for NV-Ingest to be ready (no timeout — may take 1-2 min)..."
    while true; do
        local elapsed=$(( $(date +%s) - start ))

        # Check if the process is still alive before polling the endpoint
        if ! ps -p "$pid" > /dev/null 2>&1; then
            printf "\r%-70s\n" "   ❌ NV-Ingest process died after ${elapsed}s — check logs"
            return 1
        fi

        if curl -s -f "http://${host}:${port}/v1/health/ready" > /dev/null 2>&1; then
            printf "\r%-70s\n" "   ✅ NV-Ingest is ready (${elapsed}s)"
            return 0
        fi

        printf "\r   ⏳ Loading... %ds" "$elapsed"
        sleep 2
    done
}

# ==============================================================================
# Prerequisite Checks
# ==============================================================================

check_prerequisite() {
    local service=$1
    local host=$2
    local port=$3

    if ! nc -z $host $port > /dev/null 2>&1; then
        echo "   ❌ $service not reachable at $host:$port"
        return 1
    fi
    echo "   ✅ $service ready at $host:$port"
    return 0
}

echo "=== Starting NV-Ingest Microservice ==="
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

echo "Checking prerequisites..."
MISSING_PREREQS=0

check_prerequisite "Redis" $REDIS_HOST $REDIS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "PaddleOCR" localhost $PADDLE_OCR_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Page Elements" localhost $PAGE_ELEMENTS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))

if [ $MISSING_PREREQS -gt 0 ]; then
    echo ""
    echo "❌ Missing $MISSING_PREREQS prerequisite(s)"
    echo "   Run the previous scripts first:"
    echo "   - 04-start-redis.sh"
    echo "   - 05-start-nim-models.sh"
    exit 1
fi

echo ""

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/nv-ingest.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/nv-ingest.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  NV-Ingest already running (PID $EXISTING_PID)"
        exit 0
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/nv-ingest.pid
    fi
fi

echo "Starting NV-Ingest Microservice..."

# Create data directory for NV-Ingest if needed
mkdir -p $RAG_RUNTIME_DIR/nv-ingest-data

# ==============================================================================
# Patch build_markdown() in NV-Ingest SIF (fixes IndexError with sparse tables)
#
# The system Python inside the SIF has a bug in
# nv_ingest_api/util/image_processing/table_and_chart.py:
# df["col_ids"][i] uses label-based indexing that raises
#   IndexError: single positional indexer is out-of-bounds
# for sparse YOLOX table-structure output (non-contiguous DataFrame index).
#
# Strategy: extract the file from the SIF on first run, apply the fix with
# patches/patch_build_markdown.py, then bind-mount the patched file over the
# original. No writable-tmpfs needed — single-file bind works on all kernels.
# ==============================================================================

PATCH_DIR="$(cd "$(dirname "$0")/../patches" && pwd)"
PATCH_SCRIPT="$PATCH_DIR/patch_build_markdown.py"
TABLE_CHART_PATCHED="$PATCH_DIR/table_and_chart.py"
SINGULARITY_EXTRA_ARGS=()

if [ -f "$PATCH_SCRIPT" ]; then
    echo "Applying build_markdown() patch..."

    # Discover table_and_chart.py path inside the SIF using find (robust
    # across conda/venv layouts where python3 may not be in PATH)
    TABLE_CHART_SIF_PATH=$(singularity exec \
        "$RAG_IMAGES_DIR/nv-ingest.sif" \
        find / -path "*/nv_ingest_api/util/image_processing/table_and_chart.py" \
               -not -path "*/proc/*" -not -path "*/sys/*" \
        2>/dev/null | head -1 | tr -d '\r\n')

    if [ -z "$TABLE_CHART_SIF_PATH" ]; then
        echo "   ⚠️  Could not locate table_and_chart.py inside SIF — skipping patch"
    else
        echo "   SIF path: $TABLE_CHART_SIF_PATH"

        if [ ! -f "$TABLE_CHART_PATCHED" ]; then
            echo "   Extracting and patching (first-time setup)..."
            _TMP_ORIG="$(mktemp /tmp/table_chart_orig_XXXXXX.py)"
            singularity exec "$RAG_IMAGES_DIR/nv-ingest.sif" \
                cat "$TABLE_CHART_SIF_PATH" > "$_TMP_ORIG" 2>/dev/null
            python3 "$PATCH_SCRIPT" "$_TMP_ORIG" "$TABLE_CHART_PATCHED"
            rm -f "$_TMP_ORIG"
            echo "   ✅ Patched file ready"
        else
            echo "   ✅ Patched file already exists — reusing"
        fi

        SINGULARITY_EXTRA_ARGS+=("--bind" "${TABLE_CHART_PATCHED}:${TABLE_CHART_SIF_PATH}")
        echo "   ✅ Bind-mount: $TABLE_CHART_PATCHED → $TABLE_CHART_SIF_PATH"
    fi
else
    echo "   ⚠️  Patch script not found at $PATCH_SCRIPT — running without build_markdown fix"
fi

echo ""

singularity run \
  --nv \
  "${SINGULARITY_EXTRA_ARGS[@]}" \
  --env CUDA_VISIBLE_DEVICES=$NVINGEST_GPU_ID \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env NVIDIA_BUILD_API_KEY=$NGC_API_KEY \
  --env MESSAGE_CLIENT_HOST=$REDIS_HOST \
  --env MESSAGE_CLIENT_PORT=$REDIS_PORT \
  --env MESSAGE_CLIENT_TYPE=redis \
  --env REDIS_MORPHEUS_TASK_QUEUE=morpheus_task_queue \
  --env OCR_HTTP_ENDPOINT="http://localhost:${PADDLE_OCR_PORT}/v1/infer" \
  --env OCR_GRPC_ENDPOINT="localhost:$((PADDLE_OCR_PORT + 1))" \
  --env OCR_INFER_PROTOCOL=grpc \
  --env OCR_MODEL_NAME=paddle \
  --env YOLOX_HTTP_ENDPOINT="http://localhost:${PAGE_ELEMENTS_PORT}/v1/infer" \
  --env YOLOX_GRPC_ENDPOINT="localhost:$((PAGE_ELEMENTS_PORT + 1))" \
  --env YOLOX_INFER_PROTOCOL=grpc \
  --env YOLOX_GRAPHIC_ELEMENTS_HTTP_ENDPOINT="http://localhost:${GRAPHIC_ELEMENTS_PORT}/v1/infer" \
  --env YOLOX_GRAPHIC_ELEMENTS_GRPC_ENDPOINT="localhost:$((GRAPHIC_ELEMENTS_PORT + 1))" \
  --env YOLOX_GRAPHIC_ELEMENTS_INFER_PROTOCOL=grpc \
  --env YOLOX_TABLE_STRUCTURE_HTTP_ENDPOINT="http://localhost:${TABLE_STRUCTURE_PORT}/v1/infer" \
  --env YOLOX_TABLE_STRUCTURE_GRPC_ENDPOINT="localhost:$((TABLE_STRUCTURE_PORT + 1))" \
  --env YOLOX_TABLE_STRUCTURE_INFER_PROTOCOL=grpc \
  --env VLM_CAPTION_ENDPOINT="http://localhost:${VLM_PORT}/v1/chat/completions" \
  --env VLM_CAPTION_MODEL_NAME="nvidia/llama-3.1-nemotron-nano-vl-8b-v1" \
  --env MAX_INGEST_PROCESS_WORKERS=${MAX_INGEST_PROCESS_WORKERS:-16} \
  --env INGEST_LOG_LEVEL=WARNING \
  --env INGEST_RAY_LOG_LEVEL=PRODUCTION \
  --env MRC_IGNORE_NUMA_CHECK=1 \
  --env READY_CHECK_ALL_COMPONENTS=False \
  --env OTEL_SDK_DISABLED=true \
  --bind $RAG_RUNTIME_DIR/nv-ingest-data:/workspace/data \
  $RAG_IMAGES_DIR/nv-ingest.sif \
  > $RAG_LOGS_DIR/nv-ingest.log 2>&1 &

NVINGEST_PID=$!
echo $NVINGEST_PID > $RAG_RUNTIME_DIR/pids/nv-ingest.pid

# Verify process started
sleep 2
if ps -p $NVINGEST_PID > /dev/null; then
    echo "   ✅ NV-Ingest process started (port $NVINGEST_PORT, PID $NVINGEST_PID)"
else
    echo "   ❌ NV-Ingest failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/nv-ingest.log"
    exit 1
fi

# Wait for NV-Ingest to be ready
if ! wait_for_nvingest $NVINGEST_HOST $NVINGEST_PORT $NVINGEST_PID; then
    echo "   Check logs: tail -100 $RAG_LOGS_DIR/nv-ingest.log"
    exit 1
fi

echo ""
echo "=== NV-Ingest Started ==="
echo "✅ NV-Ingest: $NVINGEST_HOST:$NVINGEST_PORT (PID $NVINGEST_PID)"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/nv-ingest.log"
echo ""
echo "Next: Run 07-start-ingest-server.sh to start Ingestor Server"
