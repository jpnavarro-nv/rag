#!/bin/bash
# Start VLM NIM: Llama 3.1 Nemotron Nano VL 8B v1
# Optional — required for vision/image captioning workflows.
# Equivalent to Docker Compose profile "vlm".
#
# Run standalone:  bash nim-vlm.sh
# Or via full stack: bash 04-start-nim-models.sh
#
# Note: for isolated testing with health check loop, use test-vlm-only.sh instead.
set -e

source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

# Ensure VLM cache directory exists
NIM_CACHE_DIR="$RAG_BASE_DIR/models/vlm-cache"
mkdir -p "$NIM_CACHE_DIR"

echo "=== Starting VLM NIM ==="
echo "   VLM: localhost:$VLM_PORT  (GPU $VLM_GPU_ID)"
echo "   Cache: $NIM_CACHE_DIR"
echo ""

# nim_llm_sdk NIM: %startscript has --port 1977 baked in (after image rebuild).
# No startscript_cmd needed — %startscript handles the port.
start_nim_service "vlm" $VLM_PORT $VLM_GPU_ID \
    "vlm.sif" \
    "--bind $NIM_CACHE_DIR:/opt/nim/.cache --env NIM_CACHE_PATH=/opt/nim/.cache"

echo ""
echo "✅ VLM NIM launched"
echo "   Monitor: tail -f $RAG_LOGS_DIR/vlm.log"
echo "   Health:  curl http://localhost:$VLM_PORT/v1/health/ready"
echo "   Status:  singularity instance list"
echo ""
echo "⚠️  Model loads in ~5-10 min (~16GB download on first run)."
