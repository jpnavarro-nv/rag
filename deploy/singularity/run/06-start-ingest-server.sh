#!/bin/bash
# Start the Ingestor Server — the API endpoint for document ingestion.
# Run after infrastructure (01), Redis (02), NIMs (03/04) and NV-Ingest (05) are up.

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

# ==============================================================================
# Configuration
# ==============================================================================
# Internal hosts use 127.0.0.1, never `localhost`: on these nodes `getent hosts
# localhost` returns ::1 (IPv6) first, and the MinIO/Milvus clients then connect
# over [::1], where the socket hangs. All services bind 0.0.0.0, so 127.0.0.1 is
# always reachable. config.sh hard-sets these (overriding any inherited value).
INGESTOR_PORT=${INGESTOR_PORT:-8082}
INGESTOR_HOST=${INGESTOR_HOST:-127.0.0.1}

MILVUS_HOST=${MILVUS_HOST:-127.0.0.1}
MILVUS_PORT=${MILVUS_PORT:-19530}
MINIO_HOST=${MINIO_HOST:-127.0.0.1}
MINIO_PORT=${MINIO_PORT:-9010}
REDIS_HOST=${REDIS_HOST:-127.0.0.1}
REDIS_PORT=${REDIS_PORT:-6379}

EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-1977}
NVINGEST_PORT=${NVINGEST_PORT:-7670}

# ==============================================================================
# Helpers
# ==============================================================================

check_prerequisite() {
    local service=$1 host=$2 port=$3
    if ! nc -z "$host" "$port" > /dev/null 2>&1; then
        echo "   ❌ $service not reachable at $host:$port"
        return 1
    fi
    echo "   ✅ $service ready at $host:$port"
    return 0
}

# Poll /health until the server answers. The container instantiation plus import
# happen between launch and bind, so the default window is generous (300s); a
# healthy start binds in seconds. The liveness bail exits the instant the server
# dies, so the window only bounds a genuine never-binds failure.
wait_for_ingestor() {
    local host=$1 port=$2
    local max_attempts=${INGESTOR_READY_ATTEMPTS:-150}   # 150 * 2s = 300s
    local attempt=1

    echo "   ⏳ Waiting for Ingestor Server to be ready..."
    while [ $attempt -le $max_attempts ]; do
        # Capture curl's exit code without tripping `set -e`.
        local rc=0
        curl -s "http://${host}:${port}/health" > /dev/null 2>&1 || rc=$?
        if [ $rc -eq 0 ]; then
            echo "   ✅ Ingestor Server is ready"
            return 0
        fi
        # Liveness bail: the pidfile holds the singularity wrapper PID, which runs
        # uvicorn in the foreground — wrapper death == server death. Bail on the
        # wrapper, not on the (still-absent) uvicorn child during startup.
        if [ -f "$RAG_RUNTIME_DIR/pids/ingestor-server.pid" ]; then
            local pid
            pid=$(cat "$RAG_RUNTIME_DIR/pids/ingestor-server.pid")
            if ! ps -p "$pid" > /dev/null 2>&1; then
                echo "   ❌ Ingestor Server process died while waiting (PID $pid)"
                return 1
            fi
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ❌ Ingestor Server failed to become ready after $((max_attempts * 2))s"
    ss -ltnp 2>/dev/null | grep ":${port} " || echo "   (no listener on :${port})"
    return 1
}

# ==============================================================================
# Start
# ==============================================================================

echo "=== Starting Ingestor Server ==="
echo ""

if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

echo "Checking prerequisites..."
MISSING_PREREQS=0
check_prerequisite "Milvus" $MILVUS_HOST $MILVUS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "MinIO" $MINIO_HOST $MINIO_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Redis" $REDIS_HOST $REDIS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Embedding NIM" 127.0.0.1 $EMBEDDING_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "NV-Ingest" 127.0.0.1 $NVINGEST_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))

if [ $MISSING_PREREQS -gt 0 ]; then
    echo ""
    echo "❌ Missing $MISSING_PREREQS prerequisite(s)"
    echo "   Run the previous scripts first:"
    echo "   - 01-start-infrastructure.sh (Milvus, MinIO)"
    echo "   - 02-start-redis.sh"
    echo "   - 03-start-nim-models.sh + 04-wait-nim-models.sh"
    echo "   - 05-start-nv-ingest-ms.sh"
    exit 1
fi

echo ""

# Skip if already running
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

mkdir -p $RAG_RUNTIME_DIR/ingestor-temp

# venv bin overlay (one-time): lets uv create missing entry points (e.g. bulk_writer)
# on the writable host instead of the read-only SIF filesystem (Errno 30).
INGESTOR_BIN_OVERLAY="$RAG_RUNTIME_DIR/ingestor-venv-bin"
if [ ! -f "$INGESTOR_BIN_OVERLAY/uvicorn" ]; then
    echo "Setting up ingestor venv bin overlay (one-time, ~30s)..."
    mkdir -p "$INGESTOR_BIN_OVERLAY"
    singularity exec $RAG_IMAGES_DIR/ingestor-server.sif bash -c "tar -C /workspace/.venv/bin -czf - ." | tar -xzf - -C "$INGESTOR_BIN_OVERLAY/"
    echo "   ✅ venv bin overlay created at $INGESTOR_BIN_OVERLAY"
fi
# bulk_writer is a PEP 660 editable stub that uv installs as a directory, not a
# file — remove it (rm -rf, not rm -f) so uv recreates it as a script on startup.
rm -rf "$INGESTOR_BIN_OVERLAY/bulk_writer"

# HF_*_OFFLINE: the compute node has no outbound internet, so make any stray
# huggingface_hub call fail fast / cache-only instead of waiting on a connect timeout.
singularity exec \
  --bind "$INGESTOR_BIN_OVERLAY:/workspace/.venv/bin" \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env HF_HUB_OFFLINE=1 \
  --env TRANSFORMERS_OFFLINE=1 \
  --env HF_HUB_DISABLE_TELEMETRY=1 \
  --env HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
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
  --env APP_EMBEDDINGS_SERVERURL="127.0.0.1:${EMBEDDING_PORT}" \
  --env APP_EMBEDDINGS_MODELNAME="nvidia/llama-3.2-nv-embedqa-1b-v2" \
  --env APP_EMBEDDINGS_DIMENSIONS=2048 \
  --env APP_NVINGEST_MESSAGECLIENTHOSTNAME=127.0.0.1 \
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
  --env APP_NVINGEST_CAPTIONENDPOINTURL="http://127.0.0.1:${VLM_PORT}/v1/chat/completions" \
  --env APP_NVINGEST_SAVETODISK=False \
  --env ENABLE_CITATIONS=${ENABLE_CITATIONS:-True} \
  --env SUMMARY_LLM="nvidia/llama-3.3-nemotron-super-49b-v1.5" \
  --env SUMMARY_LLM_SERVERURL="127.0.0.1:${LLM_PORT}" \
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
  /workspace/.venv/bin/uvicorn nvidia_rag.ingestor_server.server:app \
    --host 0.0.0.0 --port "$INGESTOR_PORT" --workers 1 \
  > $RAG_LOGS_DIR/ingestor-server.log 2>&1 &

# $! is the singularity wrapper PID (it runs uvicorn in the foreground), so the
# liveness bail in wait_for_ingestor can watch it as a proxy for the server.
INGESTOR_PID=$!
echo $INGESTOR_PID > $RAG_RUNTIME_DIR/pids/ingestor-server.pid

sleep 2
if ps -p $INGESTOR_PID > /dev/null; then
    echo "   ✅ Ingestor Server process started (port $INGESTOR_PORT, PID $INGESTOR_PID)"
else
    echo "   ❌ Ingestor Server failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/ingestor-server.log"
    exit 1
fi

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
echo "Next: Run 07-start-rag-server.sh to start the RAG Server"
