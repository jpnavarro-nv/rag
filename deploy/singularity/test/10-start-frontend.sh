#!/bin/bash
# Start RAG Frontend (Web UI)
# Run after 07-start-ingest-server.sh and 08-start-rag-server.sh
#
# The frontend is a Node.js server that:
#   - Serves the React UI (static files from /dist)
#   - Acts as reverse proxy: /api/generate/* → RAG Server
#                            /api/*          → Ingestor Server
#
# Port note: the container CMD hardcodes listen(3000, '0.0.0.0').
# In Docker this maps externally to 8090, but in Singularity (shared
# host network) there is no port mapping — the UI is at port 3000.
#
# Access: http://<compute-node-IP>:3000

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

FRONTEND_PORT=${FRONTEND_PORT:-3000}   # hardcoded in container CMD
FRONTEND_HOST=${FRONTEND_HOST:-localhost}

# Backend ports — must match 07/08 scripts
RAG_SERVER_PORT=${RAG_SERVER_PORT:-8081}
INGESTOR_PORT=${INGESTOR_PORT:-8082}

# ==============================================================================
# Healthcheck Function
# ==============================================================================

wait_for_frontend() {
    local host=$1
    local port=$2
    local max_attempts=20
    local attempt=1

    echo "   ⏳ Waiting for Frontend to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://${host}:${port}/" 2>/dev/null | grep -q "200"; then
            echo "   ✅ Frontend is ready"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "   ❌ Frontend failed to become ready after $((max_attempts * 2))s"
    return 1
}

echo "=== Starting RAG Frontend ==="
echo ""

# ==============================================================================
# Prerequisite Checks
# ==============================================================================

echo "Checking prerequisites..."

if ! nc -z localhost $RAG_SERVER_PORT > /dev/null 2>&1; then
    echo "❌ RAG Server not reachable at localhost:$RAG_SERVER_PORT"
    echo "   Run 08-start-rag-server.sh first"
    exit 1
fi
echo "   ✅ RAG Server ready at localhost:$RAG_SERVER_PORT"

if ! nc -z localhost $INGESTOR_PORT > /dev/null 2>&1; then
    echo "❌ Ingestor Server not reachable at localhost:$INGESTOR_PORT"
    echo "   Run 07-start-ingest-server.sh first"
    exit 1
fi
echo "   ✅ Ingestor Server ready at localhost:$INGESTOR_PORT"

echo ""

# ==============================================================================
# Already Running?
# ==============================================================================

if [ -f $RAG_RUNTIME_DIR/pids/rag-frontend.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/rag-frontend.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  Frontend already running (PID $EXISTING_PID)"
        NODE_IP=$(hostname -I | awk '{print $1}')
        echo "   UI: http://${NODE_IP}:${FRONTEND_PORT}"
        exit 0
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/rag-frontend.pid
    fi
fi

# ==============================================================================
# Start Frontend
# ==============================================================================

# Detect compute node IP for display
NODE_IP=$(hostname -I | awk '{print $1}')

echo "Starting Frontend on port $FRONTEND_PORT..."
echo "   RAG Server:      http://localhost:$RAG_SERVER_PORT/v1  (proxy target)"
echo "   Ingestor Server: http://localhost:$INGESTOR_PORT/v1    (proxy target)"
echo "   UI (local):      http://localhost:$FRONTEND_PORT"
echo "   UI (remote):     http://${NODE_IP}:${FRONTEND_PORT}"
echo ""

# The Node.js server reads VITE_API_CHAT_URL and VITE_API_VDB_URL at runtime
# to configure its reverse proxy. Since Singularity shares the host network,
# localhost resolves to the same host where the backends are running.
singularity run \
  --env VITE_API_CHAT_URL="http://localhost:${RAG_SERVER_PORT}/v1" \
  --env VITE_API_VDB_URL="http://localhost:${INGESTOR_PORT}/v1" \
  $RAG_IMAGES_DIR/rag-frontend.sif \
  > $RAG_LOGS_DIR/rag-frontend.log 2>&1 &

FRONTEND_PID=$!
echo $FRONTEND_PID > $RAG_RUNTIME_DIR/pids/rag-frontend.pid

# Verify process started
sleep 2
if ps -p $FRONTEND_PID > /dev/null; then
    echo "   ✅ Frontend process started (PID $FRONTEND_PID)"
else
    echo "   ❌ Frontend failed to start"
    echo "   Check logs: tail -30 $RAG_LOGS_DIR/rag-frontend.log"
    rm -f $RAG_RUNTIME_DIR/pids/rag-frontend.pid
    exit 1
fi

# Wait for the server to be ready
if ! wait_for_frontend $FRONTEND_HOST $FRONTEND_PORT; then
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/rag-frontend.log"
    exit 1
fi

echo ""
echo "=== Frontend Started ==="
echo "✅ Web UI: http://${NODE_IP}:${FRONTEND_PORT}"
echo ""
echo "Open this URL in your browser to use the RAG interface."
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/rag-frontend.log"
