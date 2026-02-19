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

# Persistent dirs for model weights, manifests and workspace
# /opt/nim/.cache    → model weights (persistent, large)
# /opt/nim/tmp       → manifest downloads (persistent, small)
# /opt/nim/workspace → NIM working files during init (persistent, small)
EMBEDDING_CACHE_DIR="$RAG_BASE_DIR/models/embedding-cache"
RANKING_CACHE_DIR="$RAG_BASE_DIR/models/ranking-cache"
LLM_CACHE_DIR="$RAG_BASE_DIR/models/llm-cache"
EMBEDDING_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/embedding"
RANKING_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/ranking"
mkdir -p "$EMBEDDING_CACHE_DIR" "$EMBEDDING_WORK_DIR/tmp" "$EMBEDDING_WORK_DIR/workspace"
mkdir -p "$RANKING_CACHE_DIR"   "$RANKING_WORK_DIR/tmp"   "$RANKING_WORK_DIR/workspace"
mkdir -p "$LLM_CACHE_DIR"

echo "=== Starting Retrieval NIMs ==="
echo "   Embedding:  localhost:$EMBEDDING_PORT  (GPU $EMBEDDING_GPU_ID)"
echo "   Ranking:    localhost:$RANKING_PORT  (GPU $RANKING_GPU_ID)"
echo "   LLM:        localhost:$LLM_PORT  (GPU $LLM_GPU_ID)"
echo ""

# Triton NIMs: singularity run (Docker entrypoint), port via NIM_HTTP_API_PORT
#
# NIM_HTTP_API_WORKERS: controls uvicorn HTTP workers AND the number of Triton
# Python backend stub instances spawned simultaneously. In Singularity, Python
# imports run against a read-only SquashFS filesystem which is slower than
# Docker's overlay. With the default workers=<nproc> (e.g. 16), all 16 stubs
# start concurrently and exceed the Triton Python backend health-check timeout.
# Reducing to 2 avoids the thundering-herd startup failure while still allowing
# some request concurrency.  Increase NIM_HTTP_API_WORKERS if throughput matters.
_RETRIEVAL_WORKERS=${NIM_HTTP_API_WORKERS:-2}

start_nim_service "nemoretriever-embedding" "$EMBEDDING_PORT" "$EMBEDDING_GPU_ID" \
    "nemoretriever-embedding.sif" \
    "$NVML_BIND --bind $EMBEDDING_CACHE_DIR:/opt/nim/.cache --bind $EMBEDDING_WORK_DIR/tmp:/opt/nim/tmp --bind $EMBEDDING_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$EMBEDDING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_RETRIEVAL_WORKERS"

start_nim_service "nemoretriever-ranking" "$RANKING_PORT" "$RANKING_GPU_ID" \
    "nemoretriever-ranking.sif" \
    "$NVML_BIND --bind $RANKING_CACHE_DIR:/opt/nim/.cache --bind $RANKING_WORK_DIR/tmp:/opt/nim/tmp --bind $RANKING_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$RANKING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_RETRIEVAL_WORKERS"

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
