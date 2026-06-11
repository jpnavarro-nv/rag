#!/bin/bash
# Start Ingestor Server
# Run after all infrastructure, Redis, NIMs, and NV-Ingest are running
#
# Ingestor Server is the API endpoint for document ingestion

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

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
VLM_PORT=${VLM_PORT:-1977}
NVINGEST_PORT=${NVINGEST_PORT:-7670}

# ==============================================================================
# Healthcheck Function
# ==============================================================================

# pgrep pattern that matches the REAL uvicorn child (python running the uvicorn
# script) but NOT the singularity wrapper (whose cmdline has `…/uvicorn` but no
# `…/python` before it). Used for liveness/diagnostics, not as the bail signal.
INGESTOR_UVICORN_PAT='/workspace/.venv/bin/python.*uvicorn nvidia_rag'

wait_for_ingestor() {
    local host=$1
    local port=$2
    # B3 — tolerate a pathologically slow but ALIVE cold start. On contended HPC
    # nodes the ingestor took ~920s from launch to bind (see import_logs/debug-06c,
    # job 360874: socket genuinely absent the whole 900s window, then bound clean —
    # NOT IPv6/unreachable, confirmed against control 360867). So use a generous cap,
    # kept safe by the liveness bail below (we exit the instant the server dies).
    # Default 900 attempts = 1800s; override with INGESTOR_READY_ATTEMPTS.
    # /health uses check_dependencies=False, so this only waits on the app being up.
    local max_attempts=${INGESTOR_READY_ATTEMPTS:-900}
    local attempt=1

    echo "   ⏳ Waiting for Ingestor Server to be ready..."
    echo "   ⏱  [$(date '+%FT%T%z')] readiness wait START (window=$((max_attempts * 2))s)"
    while [ $attempt -le $max_attempts ]; do
        # Capture the probe's exit code without tripping `set -e` (|| rc=$?).
        local rc=0
        curl -s "http://${host}:${port}/health" > /dev/null 2>&1 || rc=$?
        if [ $rc -eq 0 ]; then
            echo "   ✅ Ingestor Server is ready"
            echo "   ⏱  [$(date '+%FT%T%z')] became ready at attempt $attempt (~$((attempt * 2))s after wait START)"
            return 0
        fi
        # Instrument: every ~10 attempts log the curl exit code (7=conn-refused/no
        # listener, 6=DNS, 28=timeout) AND whether the real uvicorn child exists yet
        # + its age. This splits "still instantiating the container" (no child) from
        # "child alive, importing/binding slowly" (child present, etimes climbing).
        if [ $((attempt % 10)) -eq 1 ]; then
            local uv uv_msg="uvicorn child not present yet"
            uv=$(pgrep -f "$INGESTOR_UVICORN_PAT" 2>/dev/null | head -1) || true
            if [ -n "$uv" ]; then
                uv_msg="uvicorn child pid=$uv etimes=$(ps -o etimes= -p "$uv" 2>/dev/null | tr -d ' ')s"
            fi
            echo "   ⏱  [$(date '+%FT%T%z')] attempt $attempt/$max_attempts curl exit=$rc; $uv_msg"
        fi
        # Liveness bail: the singularity WRAPPER ($! in the pidfile) runs uvicorn in
        # the foreground (bash -c '…; exec uvicorn'), so wrapper death == server death
        # — exit immediately rather than burn the whole window. We bail on the wrapper,
        # NOT on the uvicorn child's absence: the child does not exist during the
        # multi-minute container/import startup, so its absence is normal, not death.
        if [ -f "$RAG_RUNTIME_DIR/pids/ingestor-server.pid" ]; then
            local pid
            pid=$(cat "$RAG_RUNTIME_DIR/pids/ingestor-server.pid")
            if ! ps -p "$pid" > /dev/null 2>&1; then
                echo "   ❌ Ingestor Server process died while waiting (wrapper PID $pid)"
                return 1
            fi
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ❌ Ingestor Server failed to become ready after $((max_attempts * 2))s"
    # Instrument: classify the failure at give-up. Probe BOTH localhost and 127.0.0.1
    # (settles any IPv4/IPv6 localhost-resolution doubt on the failing node itself),
    # report the real uvicorn child (alive=was-slow vs gone=crashed), and snapshot the
    # listener (present=bound-too-late vs absent=never-bound-in-window).
    echo "   ⏱  [$(date '+%FT%T%z')] give-up diagnostics for :${port}:"
    local rc_l=0 rc_4=0
    curl -s "http://localhost:${port}/health" > /dev/null 2>&1 || rc_l=$?
    curl -s "http://127.0.0.1:${port}/health" > /dev/null 2>&1 || rc_4=$?
    echo "     probe localhost: exit=$rc_l   probe 127.0.0.1: exit=$rc_4"
    local uv
    uv=$(pgrep -f "$INGESTOR_UVICORN_PAT" 2>/dev/null | head -1) || true
    if [ -n "$uv" ]; then
        echo "     uvicorn child: pid=$uv etimes=$(ps -o etimes= -p "$uv" 2>/dev/null | tr -d ' ')s (alive — was slow, not dead)"
    else
        echo "     uvicorn child: none found (still pre-exec, or already gone)"
    fi
    if command -v ss > /dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep ":${port} " || echo "     (no listener on :${port})"
    else
        echo "     (ss not available)"
    fi
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
    echo "   - 02-start-redis.sh"
    echo "   - 03-start-nim-models.sh + 04-wait-nim-models.sh"
    echo "   - 05-start-nv-ingest-ms.sh"
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

mkdir -p $RAG_RUNTIME_DIR/ingestor-temp

# Setup venv bin overlay (one-time): allows uv to create missing entry points (e.g. bulk_writer)
# on the writable host instead of the read-only SIF filesystem (Errno 30).
INGESTOR_BIN_OVERLAY="$RAG_RUNTIME_DIR/ingestor-venv-bin"
if [ ! -f "$INGESTOR_BIN_OVERLAY/uvicorn" ]; then
    echo "Setting up ingestor venv bin overlay (one-time, ~30s)..."
    mkdir -p "$INGESTOR_BIN_OVERLAY"
    singularity exec $RAG_IMAGES_DIR/ingestor-server.sif bash -c "tar -C /workspace/.venv/bin -czf - ." | tar -xzf - -C "$INGESTOR_BIN_OVERLAY/"
    echo "   ✅ venv bin overlay created at $INGESTOR_BIN_OVERLAY"
fi
# Remove bulk_writer on every startup so uv recreates it as a file (not directory).
# bulk_writer is a PEP 660 editable stub — uv installs it as a directory, not a
# script file, which is why rm -rf (not rm -f) is needed.
rm -rf "$INGESTOR_BIN_OVERLAY/bulk_writer"

singularity exec \
  --bind "$INGESTOR_BIN_OVERLAY:/workspace/.venv/bin" \
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
  bash -c 'echo "   ⏱  [$(date +%FT%T%z)] container entry (singularity instantiation done; pre-import)"; exec /workspace/.venv/bin/uvicorn nvidia_rag.ingestor_server.server:app --host 0.0.0.0 --port '"$INGESTOR_PORT"' --workers 1' \
  > $RAG_LOGS_DIR/ingestor-server.log 2>&1 &

INGESTOR_PID=$!
echo $INGESTOR_PID > $RAG_RUNTIME_DIR/pids/ingestor-server.pid
# Instrument: anchor the readiness window to the actual `&` launch wallclock.
# NB: $! is the singularity WRAPPER PID, not uvicorn — container instantiation +
# venv-bin overlay happen between this line and uvicorn binding :$INGESTOR_PORT.
echo "   ⏱  [$(date '+%FT%T%z')] uvicorn launched (wrapper PID $INGESTOR_PID)"

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
echo "Next: Run 07-start-rag-server.sh to start the RAG Server"
