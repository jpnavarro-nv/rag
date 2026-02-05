#!/bin/bash
# Start Ingestor Server
# Run after all infrastructure, Redis, NIMs, and NV-Ingest are running
#
# Ingestor Server is the API endpoint for document ingestion

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

INGESTOR_PORT=${INGESTOR_PORT:-8082}
INGESTOR_HOST=${INGESTOR_HOST:-localhost}

# Infrastructure
MILVUS_HOST=${MILVUS_HOST:-localhost}
MILVUS_PORT=${MILVUS_PORT:-19530}
MINIO_HOST=${MINIO_HOST:-localhost}
MINIO_PORT=${MINIO_PORT:-9010}
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}

# NIM endpoints
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-8997}
NVINGEST_PORT=${NVINGEST_PORT:-7670}

# ==============================================================================
# Healthcheck Function
# ==============================================================================

wait_for_ingestor() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    echo "   ⏳ Waiting for Ingestor Server to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://${host}:${port}/health" > /dev/null 2>&1; then
            echo "   ✅ Ingestor Server is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ❌ Ingestor Server failed to become ready after $((max_attempts * 2))s"
    return 1
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

echo "=== Starting Ingestor Server ==="
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

echo "Checking prerequisites..."
MISSING_PREREQS=0

check_prerequisite "Milvus" $MILVUS_HOST $MILVUS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "MinIO" $MINIO_HOST $MINIO_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Redis" $REDIS_HOST $REDIS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Embedding NIM" localhost $EMBEDDING_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "NV-Ingest" localhost $NVINGEST_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))

if [ $MISSING_PREREQS -gt 0 ]; then
    echo ""
    echo "❌ Missing $MISSING_PREREQS prerequisite(s)"
    echo "   Run the previous scripts first:"
    echo "   - 01-start-infrastructure.sh (Milvus, MinIO)"
    echo "   - 04-start-redis.sh"
    echo "   - 05-start-nim-models.sh"
    echo "   - 06-start-nv-ingest-ms.sh"
    exit 1
fi

echo ""

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/ingestor-server.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/ingestor-server.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  Ingestor Server already running (PID $EXISTING_PID)"
        exit 0
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/ingestor-server.pid
    fi
fi

echo "Starting Ingestor Server on port $INGESTOR_PORT..."

# Create temp directory for ingestor if needed
mkdir -p $RAG_RUNTIME_DIR/ingestor-temp

singularity exec \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env APP_VECTORSTORE_URL="http://${MILVUS_HOST}:${MILVUS_PORT}" \
  --env APP_VECTORSTORE_NAME=milvus \
  --env APP_VECTORSTORE_SEARCHTYPE=${APP_VECTORSTORE_SEARCHTYPE:-dense} \
  --env APP_VECTORSTORE_ENABLEGPUINDEX=${APP_VECTORSTORE_ENABLEGPUINDEX:-True} \
  --env APP_VECTORSTORE_ENABLEGPUSEARCH=${APP_VECTORSTORE_ENABLEGPUSEARCH:-True} \
  --env APP_VECTORSTORE_EF=${APP_VECTORSTORE_EF:-100} \
  --env COLLECTION_NAME=${COLLECTION_NAME:-multimodal_data} \
  --env MINIO_ENDPOINT="${MINIO_HOST}:${MINIO_PORT}" \
  --env MINIO_ACCESSKEY=minioadmin \
  --env MINIO_SECRETKEY=minioadmin \
  --env APP_EMBEDDINGS_SERVERURL="localhost:${EMBEDDING_PORT}" \
  --env APP_EMBEDDINGS_MODELNAME="nvidia/llama-3.2-nv-embedqa-1b-v2" \
  --env APP_EMBEDDINGS_DIMENSIONS=2048 \
  --env APP_NVINGEST_MESSAGECLIENTHOSTNAME=localhost \
  --env APP_NVINGEST_MESSAGECLIENTPORT=$NVINGEST_PORT \
  --env APP_NVINGEST_EXTRACTTEXT=True \
  --env APP_NVINGEST_EXTRACTINFOGRAPHICS=False \
  --env APP_NVINGEST_EXTRACTTABLES=True \
  --env APP_NVINGEST_EXTRACTCHARTS=True \
  --env APP_NVINGEST_EXTRACTIMAGES=False \
  --env APP_NVINGEST_PDFEXTRACTMETHOD=None \
  --env APP_NVINGEST_TEXTDEPTH=page \
  --env APP_NVINGEST_CHUNKSIZE=${APP_NVINGEST_CHUNKSIZE:-512} \
  --env APP_NVINGEST_CHUNKOVERLAP=${APP_NVINGEST_CHUNKOVERLAP:-150} \
  --env APP_NVINGEST_ENABLEPDFSPLITTER=True \
  --env APP_NVINGEST_CAPTIONMODELNAME="nvidia/llama-3.1-nemotron-nano-vl-8b-v1" \
  --env APP_NVINGEST_CAPTIONENDPOINTURL="http://localhost:${VLM_PORT}/v1/chat/completions" \
  --env APP_NVINGEST_SAVETODISK=False \
  --env ENABLE_CITATIONS=${ENABLE_CITATIONS:-True} \
  --env SUMMARY_LLM="nvidia/llama-3.3-nemotron-super-49b-v1.5" \
  --env SUMMARY_LLM_SERVERURL="localhost:${LLM_PORT}" \
  --env SUMMARY_LLM_MAX_CHUNK_LENGTH=50000 \
  --env SUMMARY_CHUNK_OVERLAP=200 \
  --env LOGLEVEL=${LOGLEVEL:-INFO} \
  --env REDIS_HOST=$REDIS_HOST \
  --env REDIS_PORT=$REDIS_PORT \
  --env REDIS_DB=0 \
  --env ENABLE_MINIO_BULK_UPLOAD=True \
  --env TEMP_DIR=/tmp-data \
  --env NV_INGEST_FILES_PER_BATCH=${NV_INGEST_FILES_PER_BATCH:-16} \
  --env NV_INGEST_CONCURRENT_BATCHES=${NV_INGEST_CONCURRENT_BATCHES:-4} \
  --bind $RAG_RUNTIME_DIR/ingestor-temp:/tmp-data \
  $RAG_IMAGES_DIR/ingestor-server.sif \
  uvicorn nvidia_rag.ingestor_server.server:app --host 0.0.0.0 --port $INGESTOR_PORT --workers 1 \
  > $RAG_LOGS_DIR/ingestor-server.log 2>&1 &

INGESTOR_PID=$!
echo $INGESTOR_PID > $RAG_RUNTIME_DIR/pids/ingestor-server.pid

# Verify process started
sleep 2
if ps -p $INGESTOR_PID > /dev/null; then
    echo "   ✅ Ingestor Server process started (port $INGESTOR_PORT, PID $INGESTOR_PID)"
else
    echo "   ❌ Ingestor Server failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/ingestor-server.log"
    exit 1
fi

# Wait for Ingestor to be ready
if ! wait_for_ingestor $INGESTOR_HOST $INGESTOR_PORT; then
    echo "   Check logs: tail -100 $RAG_LOGS_DIR/ingestor-server.log"
    exit 1
fi

echo ""
echo "=== Ingestor Server Started ==="
echo "✅ Ingestor Server: http://${INGESTOR_HOST}:${INGESTOR_PORT}"
echo "   API Docs: http://${INGESTOR_HOST}:${INGESTOR_PORT}/docs"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/ingestor-server.log"
echo ""
echo "Next: Run 08-validate-all-services.sh to validate the complete stack"
