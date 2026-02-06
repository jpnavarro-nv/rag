#!/bin/bash
# Start NIM Models (embedding, ranking, LLM, VLM, OCR, YOLOX)
# Run after 01-start-infrastructure.sh and 04-start-redis.sh
#
# These models are GPU-intensive. Ensure you have sufficient GPU resources.
# By default, different models use different GPUs via CUDA_VISIBLE_DEVICES.

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Configuration - GPU Assignment
# ==============================================================================

# NIM ports configuration
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
RANKING_PORT=${RANKING_PORT:-1976}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-8997}
PAGE_ELEMENTS_PORT=${PAGE_ELEMENTS_PORT:-8000}
GRAPHIC_ELEMENTS_PORT=${GRAPHIC_ELEMENTS_PORT:-8003}
TABLE_STRUCTURE_PORT=${TABLE_STRUCTURE_PORT:-8006}
PADDLE_OCR_PORT=${PADDLE_OCR_PORT:-8009}

# ==============================================================================
# GPU Distribution Strategy for 4 GPUs (Optimized)
# ==============================================================================
# GPU 0: Embedding & Retrieval (3 services: Embedding, Ranking, Milvus)
# GPU 1: LLM Generation (1 service: LLM - 49B model)
# GPU 2: Document Processing (4 services: YOLOX x3, PaddleOCR)
# GPU 3: Vision & Ingestion (2 services: VLM, NV-Ingest)
#
# This balances load and groups related services, avoiding Docker's
# default which overloads GPU 0 with 8 services.
# ==============================================================================

# GPU 0: Embedding & Retrieval
EMBEDDING_GPU_ID=${EMBEDDING_MS_GPU_ID:-0}
RANKING_GPU_ID=${RANKING_MS_GPU_ID:-0}

# GPU 1: LLM Generation
LLM_GPU_ID=${LLM_MS_GPU_ID:-1}

# GPU 2: Document Processing
PAGE_ELEMENTS_GPU_ID=${YOLOX_MS_GPU_ID:-2}
GRAPHIC_ELEMENTS_GPU_ID=${YOLOX_GRAPHICS_MS_GPU_ID:-2}
TABLE_STRUCTURE_GPU_ID=${YOLOX_TABLE_MS_GPU_ID:-2}
PADDLE_OCR_GPU_ID=${OCR_MS_GPU_ID:-2}

# GPU 3: Vision & Ingestion
VLM_GPU_ID=${VLM_MS_GPU_ID:-3}

# ==============================================================================
# Healthcheck Functions
# ==============================================================================

wait_for_nim_health() {
    local name=$1
    local host=$2
    local port=$3
    local max_attempts=120  # NIMs can take 2-4 minutes to load models
    local attempt=1

    echo "   ⏳ Waiting for $name to be ready (may take 2-4 min to load models)..."
    while [ $attempt -le $max_attempts ]; do
        # Try /v1/health/ready endpoint (NIM standard)
        if curl -s "http://${host}:${port}/v1/health/ready" > /dev/null 2>&1; then
            echo "   ✅ $name is ready"
            return 0
        fi
        # Fallback to /health endpoint
        if curl -s "http://${host}:${port}/health" > /dev/null 2>&1; then
            echo "   ✅ $name is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ⚠️  $name failed to become ready after $((max_attempts * 2))s"
    echo "   (Model may still be loading - check logs)"
    return 1
}

wait_for_triton_health() {
    local name=$1
    local host=$2
    local port=$3
    local max_attempts=120
    local attempt=1

    echo "   ⏳ Waiting for $name (Triton) to be ready..."
    while [ $attempt -le $max_attempts ]; do
        # Triton health endpoints
        if curl -s "http://${host}:${port}/v2/health/ready" > /dev/null 2>&1; then
            echo "   ✅ $name is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ⚠️  $name failed to become ready after $((max_attempts * 2))s"
    return 1
}

# ==============================================================================
# Helper Functions
# ==============================================================================

start_nim_service() {
    local name=$1
    local port=$2
    local gpu_id=$3
    local image=$4
    shift 4
    local extra_args="$@"

    local pid_file="$RAG_RUNTIME_DIR/pids/${name}.pid"
    local log_file="$RAG_LOGS_DIR/${name}.log"

    # Check if already running
    if [ -f "$pid_file" ]; then
        EXISTING_PID=$(cat "$pid_file")
        if ps -p $EXISTING_PID > /dev/null 2>&1; then
            echo "   ⊘  $name already running (PID $EXISTING_PID)"
            return 0
        else
            echo "   ⚠️  Stale PID file found, starting fresh..."
            rm -f "$pid_file"
        fi
    fi

    echo "[$name] Starting on port $port with GPU $gpu_id..."

    # Start NIM with GPU binding
    # Use 'singularity run' to execute the container's default entrypoint (from Docker CMD/ENTRYPOINT)
    singularity run \
      --nv \
      --env CUDA_VISIBLE_DEVICES=$gpu_id \
      --env NGC_API_KEY=$NGC_API_KEY \
      --env NVIDIA_API_KEY=$NGC_API_KEY \
      $extra_args \
      "$RAG_IMAGES_DIR/$image" \
      > "$log_file" 2>&1 &

    local pid=$!
    echo $pid > "$pid_file"

    # Verify process started
    sleep 2
    if ps -p $pid > /dev/null; then
        echo "   ✅ $name process started (port $port, GPU $gpu_id, PID $pid)"
        return 0
    else
        echo "   ❌ $name failed to start"
        echo "   Check logs: tail -20 $log_file"
        return 1
    fi
}

# ==============================================================================
# Main
# ==============================================================================

echo "=== Starting NIM Models ==="
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    echo "   Export it before running:"
    echo "   export NGC_API_KEY='your-key-here'"
    exit 1
fi

# Check if images exist
echo "Checking NIM images..."
MISSING_IMAGES=0
for image in nemoretriever-embedding.sif nemoretriever-ranking.sif nim-llm.sif; do
    if [ ! -f "$RAG_IMAGES_DIR/$image" ]; then
        echo "   ⚠️  Missing: $image"
        MISSING_IMAGES=$((MISSING_IMAGES + 1))
    fi
done

if [ $MISSING_IMAGES -gt 0 ]; then
    echo ""
    echo "⚠️  Warning: $MISSING_IMAGES NIM image(s) not found in $RAG_IMAGES_DIR"
    echo "   Build images first with: cd ../definitions && ./build-all.sh"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "=== [1/8] Starting Embedding Model ==="
if start_nim_service "nemoretriever-embedding" $EMBEDDING_PORT $EMBEDDING_GPU_ID "nemoretriever-embedding.sif"; then
    wait_for_nim_health "Embedding" localhost $EMBEDDING_PORT || true
fi

echo ""
echo "=== [2/8] Starting Ranking Model ==="
if start_nim_service "nemoretriever-ranking" $RANKING_PORT $RANKING_GPU_ID "nemoretriever-ranking.sif"; then
    wait_for_nim_health "Ranking" localhost $RANKING_PORT || true
fi

echo ""
echo "=== [3/8] Starting LLM Model ==="
if start_nim_service "nim-llm" $LLM_PORT $LLM_GPU_ID "nim-llm.sif" \
    "--env NIM_CACHE_PATH=/opt/nim/.cache"; then
    wait_for_nim_health "LLM" localhost $LLM_PORT || true
fi

echo ""
echo "=== [4/8] Starting VLM Model (for captions) ==="
if start_nim_service "vlm" $VLM_PORT $VLM_GPU_ID "vlm.sif"; then
    wait_for_nim_health "VLM" localhost $VLM_PORT || true
fi

echo ""
echo "=== [5/8] Starting Page Elements Detection (YOLOX) ==="
if start_nim_service "page-elements" $PAGE_ELEMENTS_PORT $PAGE_ELEMENTS_GPU_ID "page-elements.sif" \
    "--env NIM_HTTP_API_PORT=8000"; then
    wait_for_triton_health "Page Elements" localhost $PAGE_ELEMENTS_PORT || true
fi

echo ""
echo "=== [6/8] Starting Graphic Elements Detection ==="
if start_nim_service "graphic-elements" $GRAPHIC_ELEMENTS_PORT $GRAPHIC_ELEMENTS_GPU_ID "graphic-elements.sif" \
    "--env NIM_HTTP_API_PORT=8000"; then
    wait_for_triton_health "Graphic Elements" localhost $GRAPHIC_ELEMENTS_PORT || true
fi

echo ""
echo "=== [7/8] Starting Table Structure Detection ==="
if start_nim_service "table-structure" $TABLE_STRUCTURE_PORT $TABLE_STRUCTURE_GPU_ID "table-structure.sif" \
    "--env NIM_HTTP_API_PORT=8000"; then
    wait_for_triton_health "Table Structure" localhost $TABLE_STRUCTURE_PORT || true
fi

echo ""
echo "=== [8/8] Starting PaddleOCR ==="
if start_nim_service "paddle-ocr" $PADDLE_OCR_PORT $PADDLE_OCR_GPU_ID "paddle.sif" \
    "--env NIM_HTTP_API_PORT=8000"; then
    wait_for_triton_health "PaddleOCR" localhost $PADDLE_OCR_PORT || true
fi

echo ""
echo "=== NIM Models Started ==="
echo "✅ Embedding:         localhost:$EMBEDDING_PORT"
echo "✅ Ranking:           localhost:$RANKING_PORT"
echo "✅ LLM:               localhost:$LLM_PORT"
echo "✅ VLM:               localhost:$VLM_PORT"
echo "✅ Page Elements:     localhost:$PAGE_ELEMENTS_PORT"
echo "✅ Graphic Elements:  localhost:$GRAPHIC_ELEMENTS_PORT"
echo "✅ Table Structure:   localhost:$TABLE_STRUCTURE_PORT"
echo "✅ PaddleOCR:         localhost:$PADDLE_OCR_PORT"
echo ""
echo "⚠️  Note: Models may still be loading. Monitor logs in $RAG_LOGS_DIR/"
echo ""
echo "Next: Run 06-start-nv-ingest-ms.sh to start NV-Ingest microservice"
