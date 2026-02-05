#!/bin/bash
# Start infrastructure services: etcd, MinIO, Milvus
# Run this FIRST before starting RAG services

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Create PID directory
mkdir -p $RAG_RUNTIME_DIR/pids

echo "=== Starting RAG Infrastructure Services ==="
echo ""

# ==============================================================================
# 1. Start etcd (required by Milvus)
# ==============================================================================
echo "[1/3] Starting etcd..."

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/etcd.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/etcd.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  etcd already running (PID $EXISTING_PID)"
        ETCD_PID=$EXISTING_PID
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/etcd.pid
    fi
fi

# Start if not running
if [ -z "$ETCD_PID" ]; then
    singularity exec \
      --bind $RAG_RUNTIME_DIR/etcd-data:/etcd-data \
      $RAG_IMAGES_DIR/etcd.sif \
      /usr/local/bin/etcd \
        --data-dir=/etcd-data \
        --listen-client-urls=http://0.0.0.0:$ETCD_PORT \
        --advertise-client-urls=http://$ETCD_HOST:$ETCD_PORT \
        > $RAG_LOGS_DIR/etcd.log 2>&1 &

    ETCD_PID=$!
    echo $ETCD_PID > $RAG_RUNTIME_DIR/pids/etcd.pid

    # Verify process started
    sleep 1
    if ps -p $ETCD_PID > /dev/null; then
        echo "   ✅ etcd started (port $ETCD_PORT, PID $ETCD_PID)"
    else
        echo "   ❌ etcd failed to start"
        echo "   Check logs: tail -20 $RAG_LOGS_DIR/etcd.log"
        exit 1
    fi
fi

sleep 2

# ==============================================================================
# 2. Start MinIO (object storage)
# ==============================================================================
echo "[2/3] Starting MinIO..."

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/minio.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/minio.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  MinIO already running (PID $EXISTING_PID)"
        MINIO_PID=$EXISTING_PID
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/minio.pid
    fi
fi

# Start if not running
if [ -z "$MINIO_PID" ]; then
    singularity exec \
      --env MINIO_ROOT_USER=$MINIO_ROOT_USER \
      --env MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD \
      --bind $RAG_RUNTIME_DIR/minio-data:/data \
      $RAG_IMAGES_DIR/minio.sif \
      minio server /data \
        --console-address :$MINIO_CONSOLE_PORT \
        --address :$MINIO_PORT \
        > $RAG_LOGS_DIR/minio.log 2>&1 &

    MINIO_PID=$!
    echo $MINIO_PID > $RAG_RUNTIME_DIR/pids/minio.pid

    # Verify process started
    sleep 1
    if ps -p $MINIO_PID > /dev/null; then
        echo "   ✅ MinIO started (port $MINIO_PORT, console $MINIO_CONSOLE_PORT, PID $MINIO_PID)"
    else
        echo "   ❌ MinIO failed to start"
        echo "   Check logs: tail -20 $RAG_LOGS_DIR/minio.log"
        exit 1
    fi
fi

sleep 2

# ==============================================================================
# 3. Start Milvus (vector database)
# ==============================================================================
echo "[3/3] Starting Milvus standalone..."

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/milvus.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/milvus.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  Milvus already running (PID $EXISTING_PID)"
        MILVUS_PID=$EXISTING_PID
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/milvus.pid
    fi
fi

# Start if not running
if [ -z "$MILVUS_PID" ]; then
    # Milvus needs etcd and minio endpoints
    # Use environment variables to set component ports to avoid conflicts
    singularity exec \
      --nv \
      --env ETCD_ENDPOINTS=$ETCD_HOST:$ETCD_PORT \
      --env MINIO_ADDRESS=$MINIO_HOST:$MINIO_PORT \
      --env "KNOWHERE_GPU_MEM_POOL_SIZE=2048;4096" \
      --env ROOT_COORD_ADDRESS=localhost \
      --env ROOT_COORD_PORT=19530 \
      --env DATA_COORD_ADDRESS=localhost \
      --env DATA_COORD_PORT=13333 \
      --env QUERY_COORD_ADDRESS=localhost \
      --env QUERY_COORD_PORT=19531 \
      --env INDEX_COORD_ADDRESS=localhost \
      --env INDEX_COORD_PORT=31000 \
      --bind $RAG_RUNTIME_DIR/milvus-data:/var/lib/milvus \
      $RAG_IMAGES_DIR/milvus.sif \
      milvus run standalone \
        > $RAG_LOGS_DIR/milvus.log 2>&1 &

    MILVUS_PID=$!
    echo $MILVUS_PID > $RAG_RUNTIME_DIR/pids/milvus.pid

    # Verify process started
    sleep 1
    if ps -p $MILVUS_PID > /dev/null; then
        echo "   ✅ Milvus started (port $MILVUS_PORT, PID $MILVUS_PID)"
    else
        echo "   ❌ Milvus failed to start"
        echo "   Check logs: tail -20 $RAG_LOGS_DIR/milvus.log"
        exit 1
    fi
fi

sleep 3

# ==============================================================================
# Verify services are running
# ==============================================================================
echo ""
echo "=== Running Processes ==="
echo "etcd:   PID $ETCD_PID ($(ps -p $ETCD_PID -o state= 2>/dev/null || echo 'not running'))"
echo "MinIO:  PID $MINIO_PID ($(ps -p $MINIO_PID -o state= 2>/dev/null || echo 'not running'))"
echo "Milvus: PID $MILVUS_PID ($(ps -p $MILVUS_PID -o state= 2>/dev/null || echo 'not running'))"

echo ""
echo "=== Infrastructure Started ==="
echo "✅ etcd:   $ETCD_HOST:$ETCD_PORT"
echo "✅ MinIO:  $MINIO_HOST:$MINIO_PORT"
echo "✅ Milvus: $MILVUS_HOST:$MILVUS_PORT"
echo ""
echo "Logs available at: $RAG_LOGS_DIR/"
echo ""
echo "Next: Run 02-test-connectivity.sh to verify connectivity"
