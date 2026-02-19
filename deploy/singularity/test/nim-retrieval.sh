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

echo "=== Starting Retrieval NIMs ==="
echo "   Embedding:  localhost:$EMBEDDING_PORT  (GPU $EMBEDDING_GPU_ID)"
echo "   Ranking:    localhost:$RANKING_PORT  (GPU $RANKING_GPU_ID)"
echo "   LLM:        localhost:$LLM_PORT  (GPU $LLM_GPU_ID)"
echo ""

# Triton NIM: port via NIM_HTTP_API_PORT (belt+suspenders with %environment after rebuild)
start_nim_service "nemoretriever-embedding" $EMBEDDING_PORT $EMBEDDING_GPU_ID \
    "nemoretriever-embedding.sif" \
    "--env NIM_HTTP_API_PORT=$EMBEDDING_PORT"

start_nim_service "nemoretriever-ranking" $RANKING_PORT $RANKING_GPU_ID \
    "nemoretriever-ranking.sif" \
    "--env NIM_HTTP_API_PORT=$RANKING_PORT"

# nim_llm_sdk NIM: startscript_cmd workaround until image rebuild
# After rebuild, %startscript handles --port 8999 directly
start_nim_service "nim-llm" $LLM_PORT $LLM_GPU_ID \
    "nim-llm.sif" \
    "--env NIM_CACHE_PATH=/opt/nim/.cache" \
    "/opt/nim/start_server.sh --port $LLM_PORT"

echo ""
echo "✅ Retrieval NIMs launched"
echo "   Monitor: tail -f $RAG_LOGS_DIR/{nemoretriever-embedding,nemoretriever-ranking,nim-llm}.log"
echo "   Status:  singularity instance list"
echo ""
echo "⚠️  LLM model loads in ~10-15 min (49B). Embedding/Ranking ready in ~2 min."
