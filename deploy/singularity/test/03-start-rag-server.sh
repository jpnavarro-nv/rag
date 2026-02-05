#!/bin/bash
# Start RAG Server (requires infrastructure to be running)

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Healthcheck Functions
# ==============================================================================

# Wait for RAG Server to be ready
wait_for_rag_server() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    echo "   ⏳ Waiting for RAG Server to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s "http://${host}:${port}/health" > /dev/null 2>&1; then
            echo "   ✅ RAG Server is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ❌ RAG Server failed to become ready after $((max_attempts * 2))s"
    return 1
}

echo "=== Starting RAG Server ==="
echo ""

# Check if NGC_API_KEY is set
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    echo "   Export it before running:"
    echo "   export NGC_API_KEY='your-key-here'"
    exit 1
fi

# Check if infrastructure is running
echo "Checking infrastructure..."

# Check etcd
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

# Check MinIO
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

# Check Milvus
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
# Start RAG Server
# ==============================================================================
echo "Starting RAG Server..."

singularity exec \
  --nv \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env APP_VECTORSTORE_URL=http://$MILVUS_HOST:$MILVUS_PORT \
  --env APP_VECTORSTORE_NAME=milvus \
  --env MINIO_ENDPOINT=$MINIO_HOST:$MINIO_PORT \
  --env MINIO_ACCESSKEY=$MINIO_ROOT_USER \
  --env MINIO_SECRETKEY=$MINIO_ROOT_PASSWORD \
  --env APP_LLM_SERVERURL="" \
  --env APP_EMBEDDINGS_SERVERURL="" \
  --env APP_RANKING_SERVERURL="" \
  --env LOGLEVEL=INFO \
  $RAG_IMAGES_DIR/rag-server.sif \
  uvicorn nvidia_rag.rag_server.server:app --host 0.0.0.0 --port 8081 \
  > $RAG_LOGS_DIR/rag-server.log 2>&1 &

RAG_SERVER_PID=$!
echo $RAG_SERVER_PID > $RAG_RUNTIME_DIR/pids/rag-server.pid

# Verify process started
sleep 2
if ps -p $RAG_SERVER_PID > /dev/null; then
    echo "✅ RAG Server process started (port 8081, PID $RAG_SERVER_PID)"
else
    echo "❌ RAG Server failed to start"
    echo "Check logs: $RAG_LOGS_DIR/rag-server.log"
    exit 1
fi

# Wait for RAG Server to be ready
if ! wait_for_rag_server localhost 8081; then
    echo "Check logs: tail -50 $RAG_LOGS_DIR/rag-server.log"
    exit 1
fi

echo ""
echo "=== Running Processes ==="
if [ -f $RAG_RUNTIME_DIR/pids/etcd.pid ]; then
    ETCD_PID=$(cat $RAG_RUNTIME_DIR/pids/etcd.pid)
    echo "etcd:       PID $ETCD_PID ($(ps -p $ETCD_PID -o state= 2>/dev/null || echo 'not running'))"
fi
if [ -f $RAG_RUNTIME_DIR/pids/minio.pid ]; then
    MINIO_PID=$(cat $RAG_RUNTIME_DIR/pids/minio.pid)
    echo "MinIO:      PID $MINIO_PID ($(ps -p $MINIO_PID -o state= 2>/dev/null || echo 'not running'))"
fi
if [ -f $RAG_RUNTIME_DIR/pids/milvus.pid ]; then
    MILVUS_PID=$(cat $RAG_RUNTIME_DIR/pids/milvus.pid)
    echo "Milvus:     PID $MILVUS_PID ($(ps -p $MILVUS_PID -o state= 2>/dev/null || echo 'not running'))"
fi
echo "RAG Server: PID $RAG_SERVER_PID ($(ps -p $RAG_SERVER_PID -o state= 2>/dev/null || echo 'not running'))"

echo ""
echo "=== RAG Server ==="
echo "URL: http://localhost:8081"
echo "Health: http://localhost:8081/health"
echo "Docs: http://localhost:8081/docs"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/rag-server.log"
echo ""
echo "Next: Test with curl http://localhost:8081/health"
