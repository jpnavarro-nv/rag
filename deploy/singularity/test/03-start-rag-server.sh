#!/bin/bash
# Start RAG Server (requires infrastructure to be running)

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

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
if ! singularity instance list | grep -q "etcd-instance"; then
    echo "❌ etcd is not running. Run 01-start-infrastructure.sh first"
    exit 1
fi

if ! singularity instance list | grep -q "minio-instance"; then
    echo "❌ MinIO is not running. Run 01-start-infrastructure.sh first"
    exit 1
fi

if ! singularity instance list | grep -q "milvus-instance"; then
    echo "❌ Milvus is not running. Run 01-start-infrastructure.sh first"
    exit 1
fi

echo "✅ Infrastructure is running"
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
    echo "✅ RAG Server started (port 8081, PID $RAG_SERVER_PID)"
else
    echo "❌ RAG Server failed to start"
    echo "Check logs: $RAG_LOGS_DIR/rag-server.log"
    exit 1
fi

sleep 3

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
