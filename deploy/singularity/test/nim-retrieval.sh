#!/bin/bash
# Start Retrieval NIMs: Embedding + Ranking + LLM
# Required for all RAG query/generation workflows.
# Equivalent to Docker Compose profile "rag".
#
# Run standalone:  bash nim-retrieval.sh
# Or via full stack: bash 04-start-nim-models.sh
set -e

source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

# Writable cache dirs for model weights
EMBEDDING_CACHE_DIR="$RAG_BASE_DIR/models/embedding-cache"
RANKING_CACHE_DIR="$RAG_BASE_DIR/models/ranking-cache"
LLM_CACHE_DIR="$RAG_BASE_DIR/models/llm-cache"
mkdir -p "$EMBEDDING_CACHE_DIR" "$RANKING_CACHE_DIR" "$LLM_CACHE_DIR"

echo "=== Starting Retrieval NIMs ==="
echo "   Embedding:  localhost:$EMBEDDING_PORT  (GPU $EMBEDDING_GPU_ID)"
echo "   Ranking:    localhost:$RANKING_PORT  (GPU $RANKING_GPU_ID)"
echo "   LLM:        localhost:$LLM_PORT  (GPU $LLM_GPU_ID)"
echo ""

# Triton NIMs: singularity run (Docker entrypoint), port via NIM_HTTP_API_PORT
start_nim_service "nemoretriever-embedding" "$EMBEDDING_PORT" "$EMBEDDING_GPU_ID" \
    "nemoretriever-embedding.sif" \
    "$NVML_BIND --bind $EMBEDDING_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$EMBEDDING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

start_nim_service "nemoretriever-ranking" "$RANKING_PORT" "$RANKING_GPU_ID" \
    "nemoretriever-ranking.sif" \
    "$NVML_BIND --bind $RANKING_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$RANKING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

# nim_llm_sdk NIM: singularity exec with explicit start_server.sh --port
# --cleanenv + MPI suppression same as VLM (same family, same HPC issues)
LLM_OPTS="--cleanenv --bind $LLM_CACHE_DIR:/opt/nim/.cache --env NIM_CACHE_PATH=/opt/nim/.cache --env OMPI_MCA_pmix=^all --env OMPI_MCA_pml=ob1 --env PMIX_MCA_gds=^ds12,ds21 --env PMIX_MCA_psec=^munge"

start_nim_service "nim-llm" "$LLM_PORT" "$LLM_GPU_ID" \
    "nim-llm.sif" \
    "$LLM_OPTS" \
    "/opt/nim/start_server.sh --port $LLM_PORT"

echo ""
echo "✅ Retrieval NIMs launched"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nemoretriever-embedding.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nemoretriever-ranking.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nim-llm.log"
echo ""
echo "⚠️  LLM (49B) loads in ~10-15 min. Embedding/Ranking ready in ~2 min."
