#!/bin/bash
# Start RAG Server
# Run after 01-start-infrastructure.sh. NIMs (04+05) and app layer (06+07) must be
# running for queries to work — not verified here, server starts regardless.
#
# RAG Server orchestrates all calls to NIMs, Milvus, and MinIO to answer user queries

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

RAG_SERVER_PORT=${RAG_SERVER_PORT:-8081}
RAG_SERVER_HOST=${RAG_SERVER_HOST:-localhost}

# Infrastructure — must match config.sh
MILVUS_HOST=${MILVUS_HOST:-localhost}
MILVUS_PORT=${MILVUS_PORT:-19530}
MINIO_HOST=${MINIO_HOST:-localhost}
MINIO_PORT=${MINIO_PORT:-9010}

# NIM endpoints — must match ports in nim-lib.sh / nim-retrieval.sh
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
RANKING_PORT=${RANKING_PORT:-1976}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-1977}

# ==============================================================================
# Healthcheck Function
# ==============================================================================

wait_for_rag_server() {
    local host=$1
    local port=$2
    local pid=$3
    local start
    start=$(date +%s)

    echo "   ⏳ Waiting for RAG Server to be ready (no timeout)..."
    while true; do
        local elapsed=$(( $(date +%s) - start ))

        # Check if the process is still alive before polling the endpoint
        if ! ps -p "$pid" > /dev/null 2>&1; then
            printf "\r%-70s\n" "   ❌ RAG Server process died after ${elapsed}s — check logs"
            return 1
        fi

        if curl -s -f "http://${host}:${port}/health" > /dev/null 2>&1; then
            printf "\r%-70s\n" "   ✅ RAG Server is ready (${elapsed}s)"
            return 0
        fi

        printf "\r   ⏳ Loading... %ds" "$elapsed"
        sleep 2
    done
}

echo "=== Starting RAG Server ==="
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    echo "   Export it before running:"
    echo "   export NGC_API_KEY='your-key-here'"
    exit 1
fi

# ==============================================================================
# Prerequisite Checks
# ==============================================================================

echo "Checking infrastructure..."

if [ ! -f $RAG_RUNTIME_DIR/pids/etcd.pid ]; then
    echo "❌ etcd PID file not found. Run 01-start-infrastructure.sh first"
    exit 1
fi
ETCD_PID=$(cat $RAG_RUNTIME_DIR/pids/etcd.pid)
if ! ps -p $ETCD_PID > /dev/null 2>&1; then
    echo "❌ etcd is not running (stale PID $ETCD_PID). Run 01-start-infrastructure.sh"
    exit 1
fi
echo "   ✅ etcd running (PID $ETCD_PID)"

if [ ! -f $RAG_RUNTIME_DIR/pids/minio.pid ]; then
    echo "❌ MinIO PID file not found. Run 01-start-infrastructure.sh first"
    exit 1
fi
MINIO_PID=$(cat $RAG_RUNTIME_DIR/pids/minio.pid)
if ! ps -p $MINIO_PID > /dev/null 2>&1; then
    echo "❌ MinIO is not running (stale PID $MINIO_PID). Run 01-start-infrastructure.sh"
    exit 1
fi
echo "   ✅ MinIO running (PID $MINIO_PID)"

if [ ! -f $RAG_RUNTIME_DIR/pids/milvus.pid ]; then
    echo "❌ Milvus PID file not found. Run 01-start-infrastructure.sh first"
    exit 1
fi
MILVUS_PID=$(cat $RAG_RUNTIME_DIR/pids/milvus.pid)
if ! ps -p $MILVUS_PID > /dev/null 2>&1; then
    echo "❌ Milvus is not running (stale PID $MILVUS_PID). Run 01-start-infrastructure.sh"
    exit 1
fi
echo "   ✅ Milvus running (PID $MILVUS_PID)"

echo ""
echo "✅ All infrastructure services are running"
echo ""

# ==============================================================================
# Already Running?
# ==============================================================================

if [ -f $RAG_RUNTIME_DIR/pids/rag-server.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/rag-server.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  RAG Server already running (PID $EXISTING_PID)"
        exit 0
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/rag-server.pid
    fi
fi

# ==============================================================================
# Start RAG Server
# ==============================================================================

echo "Starting RAG Server on port $RAG_SERVER_PORT..."
echo "   LLM:       localhost:$LLM_PORT"
echo "   Embedding: localhost:$EMBEDDING_PORT"
echo "   Ranking:   localhost:$RANKING_PORT"
echo "   VLM:       http://localhost:$VLM_PORT/v1"
echo ""

# Temp dir for Prometheus multi-process metrics
mkdir -p $RAG_RUNTIME_DIR/rag-server-temp/prom_data

# Custom prompt file — mounted into the container at /prompt_petrobras.yaml
# The RAG server merges this over the built-in prompt.yaml via PROMPT_CONFIG_FILE.
# To revert to the default prompts, comment out the two lines below.
PROMPT_FILE="$(cd "$(dirname "$0")/../../.." && pwd)/src/nvidia_rag/rag_server/prompt_petrobras.yaml"

singularity exec \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env APP_VECTORSTORE_URL="http://${MILVUS_HOST}:${MILVUS_PORT}" \
  --env APP_VECTORSTORE_NAME=milvus \
  --env APP_VECTORSTORE_INDEXTYPE=${APP_VECTORSTORE_INDEXTYPE:-GPU_CAGRA} \
  --env APP_VECTORSTORE_SEARCHTYPE=${APP_VECTORSTORE_SEARCHTYPE:-dense} \
  --env APP_VECTORSTORE_ENABLEGPUSEARCH=${APP_VECTORSTORE_ENABLEGPUSEARCH:-True} \
  --env APP_VECTORSTORE_EF=${APP_VECTORSTORE_EF:-100} \
  --env COLLECTION_NAME=${COLLECTION_NAME:-multimodal_data} \
  --env APP_RETRIEVER_SCORETHRESHOLD=${APP_RETRIEVER_SCORETHRESHOLD:-0.25} \
  --env VECTOR_DB_TOPK=${VECTOR_DB_TOPK:-100} \
  --env MINIO_ENDPOINT="${MINIO_HOST}:${MINIO_PORT}" \
  --env MINIO_ACCESSKEY=$MINIO_ROOT_USER \
  --env MINIO_SECRETKEY=$MINIO_ROOT_PASSWORD \
  --env APP_LLM_MODELNAME=${APP_LLM_MODELNAME:-"nvidia/llama-3.3-nemotron-super-49b-v1.5"} \
  --env APP_LLM_SERVERURL="localhost:${LLM_PORT}" \
  --env LLM_MAX_TOKENS=${LLM_MAX_TOKENS:-32768} \
  --env LLM_TEMPERATURE=${LLM_TEMPERATURE:-0.6} \
  --env LLM_TOP_P=${LLM_TOP_P:-0.95} \
  --env APP_QUERYREWRITER_MODELNAME=${APP_QUERYREWRITER_MODELNAME:-"nvidia/llama-3.3-nemotron-super-49b-v1.5"} \
  --env APP_QUERYREWRITER_SERVERURL="localhost:${LLM_PORT}" \
  --env ENABLE_QUERYREWRITER=${ENABLE_QUERYREWRITER:-False} \
  --env APP_FILTEREXPRESSIONGENERATOR_MODELNAME=${APP_FILTEREXPRESSIONGENERATOR_MODELNAME:-"nvidia/llama-3.3-nemotron-super-49b-v1.5"} \
  --env APP_FILTEREXPRESSIONGENERATOR_SERVERURL="localhost:${LLM_PORT}" \
  --env ENABLE_FILTER_GENERATOR=${ENABLE_FILTER_GENERATOR:-False} \
  --env APP_EMBEDDINGS_SERVERURL="localhost:${EMBEDDING_PORT}" \
  --env APP_EMBEDDINGS_MODELNAME=${APP_EMBEDDINGS_MODELNAME:-"nvidia/llama-3.2-nv-embedqa-1b-v2"} \
  --env APP_RANKING_SERVERURL="localhost:${RANKING_PORT}" \
  --env APP_RANKING_MODELNAME=${APP_RANKING_MODELNAME:-"nvidia/llama-3.2-nv-rerankqa-1b-v2"} \
  --env ENABLE_RERANKER=${ENABLE_RERANKER:-True} \
  --env RERANKER_CONFIDENCE_THRESHOLD=${RERANKER_CONFIDENCE_THRESHOLD:-0.0} \
  --env ENABLE_VLM_INFERENCE=${ENABLE_VLM_INFERENCE:-false} \
  --env APP_VLM_SERVERURL="http://localhost:${VLM_PORT}/v1" \
  --env APP_VLM_MODELNAME=${APP_VLM_MODELNAME:-"nvidia/llama-3.1-nemotron-nano-vl-8b-v1"} \
  --env APP_VLM_MAX_TOTAL_IMAGES=${APP_VLM_MAX_TOTAL_IMAGES:-4} \
  --env APP_VLM_MAX_QUERY_IMAGES=${APP_VLM_MAX_QUERY_IMAGES:-1} \
  --env APP_VLM_MAX_CONTEXT_IMAGES=${APP_VLM_MAX_CONTEXT_IMAGES:-1} \
  --env APP_RETRIEVER_TOPK=${APP_RETRIEVER_TOPK:-10} \
  --env ENABLE_CITATIONS=${ENABLE_CITATIONS:-True} \
  --env ENABLE_GUARDRAILS=${ENABLE_GUARDRAILS:-False} \
  --env ENABLE_REFLECTION=${ENABLE_REFLECTION:-false} \
  --env REFLECTION_LLM=${REFLECTION_LLM:-"nvidia/llama-3.3-nemotron-super-49b-v1.5"} \
  --env REFLECTION_LLM_SERVERURL="localhost:${LLM_PORT}" \
  --env ENABLE_SOURCE_METADATA=${ENABLE_SOURCE_METADATA:-true} \
  --env FILTER_THINK_TOKENS=${FILTER_THINK_TOKENS:-true} \
  --env CONVERSATION_HISTORY=${CONVERSATION_HISTORY:-5} \
  --env APP_TRACING_ENABLED=${APP_TRACING_ENABLED:-False} \
  --env PROMETHEUS_MULTIPROC_DIR=/tmp-data/prom_data \
  --env LOGLEVEL=${LOGLEVEL:-INFO} \
  --env PROMPT_CONFIG_FILE=/prompt_petrobras.yaml \
  --bind $RAG_RUNTIME_DIR/rag-server-temp:/tmp-data \
  --bind "${PROMPT_FILE}:/prompt_petrobras.yaml" \
  $RAG_IMAGES_DIR/rag-server.sif \
  uvicorn nvidia_rag.rag_server.server:app --host 0.0.0.0 --port $RAG_SERVER_PORT --workers 8 \
  > $RAG_LOGS_DIR/rag-server.log 2>&1 &

RAG_SERVER_PID=$!
echo $RAG_SERVER_PID > $RAG_RUNTIME_DIR/pids/rag-server.pid

# Verify process started
sleep 2
if ps -p $RAG_SERVER_PID > /dev/null; then
    echo "   ✅ RAG Server process started (port $RAG_SERVER_PORT, PID $RAG_SERVER_PID)"
else
    echo "   ❌ RAG Server failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/rag-server.log"
    exit 1
fi

# Wait for RAG Server to be ready
if ! wait_for_rag_server $RAG_SERVER_HOST $RAG_SERVER_PORT $RAG_SERVER_PID; then
    echo "   Check logs: tail -100 $RAG_LOGS_DIR/rag-server.log"
    exit 1
fi

echo ""
echo "=== RAG Server Started ==="
echo "✅ RAG Server: http://${RAG_SERVER_HOST}:${RAG_SERVER_PORT}"
echo "   API Docs:   http://${RAG_SERVER_HOST}:${RAG_SERVER_PORT}/docs"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/rag-server.log"
echo ""
echo "Next: Run 08-start-frontend.sh to start the Web UI"
