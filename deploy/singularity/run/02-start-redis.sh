#!/bin/bash
# Start Redis (required by ingestor-server and nv-ingest)
# Run after 01-start-infrastructure.sh

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

# ==============================================================================
# Healthcheck Function
# ==============================================================================

wait_for_redis() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    echo "   ⏳ Waiting for Redis to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if redis-cli -h $host -p $port ping > /dev/null 2>&1; then
            echo "   ✅ Redis is ready"
            return 0
        fi
        # Fallback to nc if redis-cli not available
        if command -v nc > /dev/null 2>&1; then
            if nc -z $host $port > /dev/null 2>&1; then
                echo "   ✅ Redis is ready (via nc)"
                return 0
            fi
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    echo "   ❌ Redis failed to become ready after ${max_attempts}s"
    return 1
}

echo "=== Starting Redis ==="
echo ""

REDIS_PORT=${REDIS_PORT:-6379}
REDIS_HOST=${REDIS_HOST:-localhost}

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/redis.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/redis.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  Redis already running (PID $EXISTING_PID)"
        REDIS_PID=$EXISTING_PID
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/redis.pid
    fi
fi

# Start if not running
if [ -z "$REDIS_PID" ]; then
    echo "Starting Redis on port $REDIS_PORT..."

    singularity exec \
      $RAG_IMAGES_DIR/redis.sif \
      redis-server \
        --port $REDIS_PORT \
        --bind 0.0.0.0 \
        --protected-mode no \
        --dir /tmp \
        > $RAG_LOGS_DIR/redis.log 2>&1 &

    REDIS_PID=$!
    echo $REDIS_PID > $RAG_RUNTIME_DIR/pids/redis.pid

    # Verify process started
    sleep 1
    if ps -p $REDIS_PID > /dev/null; then
        echo "   ✅ Redis process started (port $REDIS_PORT, PID $REDIS_PID)"
    else
        echo "   ❌ Redis failed to start"
        echo "   Check logs: tail -20 $RAG_LOGS_DIR/redis.log"
        exit 1
    fi

    if ! wait_for_redis $REDIS_HOST $REDIS_PORT; then
        echo "   Check logs: tail -20 $RAG_LOGS_DIR/redis.log"
        exit 1
    fi
fi

echo ""
echo "=== Redis Started ==="
echo "✅ Redis: $REDIS_HOST:$REDIS_PORT (PID $REDIS_PID)"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/redis.log"
echo ""
echo "Next: Run 03-start-nim-models.sh to start NIM models"
