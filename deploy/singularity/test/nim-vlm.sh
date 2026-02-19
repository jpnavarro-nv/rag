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

# Writable cache for model weights
NIM_CACHE_DIR="$RAG_BASE_DIR/models/vlm-cache"
mkdir -p "$NIM_CACHE_DIR"

echo "=== Starting VLM NIM ==="
echo "   VLM: localhost:$VLM_PORT  (GPU $VLM_GPU_ID)"
echo "   Cache: $NIM_CACHE_DIR"
echo ""

# nim_llm_sdk NIM:
#   --cleanenv: strip HPC host vars (MPI/PMIx) that cause noise/conflicts
#   --bind: writable cache for model weights
#   --env OMPI/PMIX: suppress MPI warnings in HPC environments
#   exec_cmd: port passed via start_server.sh "$@" -> api_server.py --port
VLM_OPTS="--cleanenv --bind $NIM_CACHE_DIR:/opt/nim/.cache --env NIM_TENSOR_PARALLEL_SIZE=1 --env NIM_PIPELINE_PARALLEL_SIZE=1 --env NIM_CACHE_PATH=/opt/nim/.cache --env OMPI_MCA_pmix=^all --env OMPI_MCA_pml=ob1 --env PMIX_MCA_gds=^ds12,ds21 --env PMIX_MCA_psec=^munge"

start_nim_service "vlm" "$VLM_PORT" "$VLM_GPU_ID" \
    "vlm.sif" \
    "$VLM_OPTS" \
    "/opt/nim/start_server.sh --port $VLM_PORT"

echo ""
echo "Monitor:  tail -f $RAG_LOGS_DIR/vlm.log"
echo "Health:   curl http://localhost:$VLM_PORT/v1/health/ready"
echo "Stop:     kill \$(cat $RAG_RUNTIME_DIR/pids/vlm.pid)"
echo ""
echo "⚠️  Model loads in ~5-10 min (~16GB download on first run)."
