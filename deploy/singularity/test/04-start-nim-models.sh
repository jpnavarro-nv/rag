#!/bin/bash
# Start NIM Models (embedding, ranking, LLM, VLM, OCR, YOLOX)
# Run after 01-start-infrastructure.sh and 03-start-redis.sh
#
# This script launches all NIMs in parallel (non-blocking).
# Use 05-wait-nim-models.sh to wait for readiness before proceeding.
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
# Helper Functions
# ==============================================================================

start_nim_service() {
    local name=$1
    local port=$2
    local gpu_id=$3
    local image=$4
    shift 4
    local extra_args="$@"

    local instance_name="nim-${name}"
    local log_file="$RAG_LOGS_DIR/${name}.log"

    # Check if already running
    if singularity instance list | grep -q "^${instance_name}"; then
        echo "   ⊘  $name already running (instance: $instance_name)"
        return 0
    fi

    echo "[$name] Starting on port $port with GPU $gpu_id..."

    # Start NIM instance using .def file's %startscript
    singularity instance start \
      --nv \
      --env CUDA_VISIBLE_DEVICES=$gpu_id \
      --env NGC_API_KEY=$NGC_API_KEY \
      --env NVIDIA_API_KEY=$NGC_API_KEY \
      $extra_args \
      "$RAG_IMAGES_DIR/$image" \
      "$instance_name" \
      > "$log_file" 2>&1

    # Brief check that instance started
    if singularity instance list | grep -q "^${instance_name}"; then
        echo "   ✅ $name instance started (port $port, GPU $gpu_id, instance: $instance_name)"
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
start_nim_service "nemoretriever-embedding" $EMBEDDING_PORT $EMBEDDING_GPU_ID "nemoretriever-embedding.sif"

echo ""
echo "=== [2/8] Starting Ranking Model ==="
start_nim_service "nemoretriever-ranking" $RANKING_PORT $RANKING_GPU_ID "nemoretriever-ranking.sif"

echo ""
echo "=== [3/8] Starting LLM Model ==="
start_nim_service "nim-llm" $LLM_PORT $LLM_GPU_ID "nim-llm.sif" \
    "--env NIM_CACHE_PATH=/opt/nim/.cache"

echo ""
echo "=== [4/8] Starting VLM Model (for captions) ==="
start_nim_service "vlm" $VLM_PORT $VLM_GPU_ID "vlm.sif"

echo ""
echo "=== [5/8] Starting Page Elements Detection (YOLOX) ==="
start_nim_service "page-elements" $PAGE_ELEMENTS_PORT $PAGE_ELEMENTS_GPU_ID "page-elements.sif" \
    "--env NIM_HTTP_API_PORT=8000"

echo ""
echo "=== [6/8] Starting Graphic Elements Detection ==="
start_nim_service "graphic-elements" $GRAPHIC_ELEMENTS_PORT $GRAPHIC_ELEMENTS_GPU_ID "graphic-elements.sif" \
    "--env NIM_HTTP_API_PORT=8000"

echo ""
echo "=== [7/8] Starting Table Structure Detection ==="
start_nim_service "table-structure" $TABLE_STRUCTURE_PORT $TABLE_STRUCTURE_GPU_ID "table-structure.sif" \
    "--env NIM_HTTP_API_PORT=8000"

echo ""
echo "=== [8/8] Starting PaddleOCR ==="
start_nim_service "paddle-ocr" $PADDLE_OCR_PORT $PADDLE_OCR_GPU_ID "paddle.sif" \
    "--env NIM_HTTP_API_PORT=8000"

echo ""
echo "=== NIM Models Launched ==="
echo "✅ Embedding:         localhost:$EMBEDDING_PORT (instance: nim-nemoretriever-embedding)"
echo "✅ Ranking:           localhost:$RANKING_PORT (instance: nim-nemoretriever-ranking)"
echo "✅ LLM:               localhost:$LLM_PORT (instance: nim-nim-llm)"
echo "✅ VLM:               localhost:$VLM_PORT (instance: nim-vlm)"
echo "✅ Page Elements:     localhost:$PAGE_ELEMENTS_PORT (instance: nim-page-elements)"
echo "✅ Graphic Elements:  localhost:$GRAPHIC_ELEMENTS_PORT (instance: nim-graphic-elements)"
echo "✅ Table Structure:   localhost:$TABLE_STRUCTURE_PORT (instance: nim-table-structure)"
echo "✅ PaddleOCR:         localhost:$PADDLE_OCR_PORT (instance: nim-paddle-ocr)"
echo ""
echo "⚠️  Note: NIMs are loading models in background (5-10 min)"
echo "   Check status: singularity instance list"
echo "   Monitor logs: tail -f $RAG_LOGS_DIR/*.log"
echo ""
echo "Next: Run 05-wait-nim-models.sh to wait for NIMs to become ready"
