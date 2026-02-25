#!/bin/bash
# Start infrastructure services: etcd, MinIO, Milvus
#
# Must be the FIRST script run in every new session.
# - Stops any services left over from the previous session
# - Creates a fresh exec_YYYY_MM_DD_N directory for logs and runtime state
# - Starts etcd, MinIO, and Milvus (data persisted in db/ across sessions)

set -e

# ==============================================================================
# Step 1: Determine base directory (same default as config.sh)
# ==============================================================================
_RAG_BASE_DIR=${RAG_BASE_DIR:-$HOME/rag-test}

# ==============================================================================
# Step 2: Stop any services left over from the previous session
# ==============================================================================
echo "=== Cleaning up previous session ==="
_PREV_EXEC_FILE="$_RAG_BASE_DIR/.current_exec"
if [ -f "$_PREV_EXEC_FILE" ]; then
    _PREV_EXEC=$(cat "$_PREV_EXEC_FILE")
    _PREV_NAME=$(basename "$_PREV_EXEC")
    echo "   Previous session: $_PREV_NAME"
    if [ -d "$_PREV_EXEC/runtime/pids" ]; then
        for _pid_file in "$_PREV_EXEC/runtime/pids/"*.pid; do
            [ -f "$_pid_file" ] || continue
            _pid=$(cat "$_pid_file")
            _svc=$(basename "$_pid_file" .pid)
            if ps -p "$_pid" > /dev/null 2>&1; then
                echo "   Stopping $_svc (PID $_pid)..."
                kill "$_pid" 2>/dev/null || true
                pkill -P "$_pid" 2>/dev/null || true
            fi
        done
        sleep 3
        # Force-kill anything still alive
        for _pid_file in "$_PREV_EXEC/runtime/pids/"*.pid; do
            [ -f "$_pid_file" ] || continue
            _pid=$(cat "$_pid_file")
            if ps -p "$_pid" > /dev/null 2>&1; then
                kill -9 "$_pid" 2>/dev/null || true
            fi
            rm -f "$_pid_file"
        done
    else
        echo "   No PID files found in previous session"
    fi
else
    echo "   No previous session found"
fi

# Kill Ray grandchild processes (not tracked in PID files)
for _pat in "raylet" "ray::" "gcs_server" "plasma_store_server" "dashboard_agent" "ray/dashboard"; do
    pkill -f "$_pat" 2>/dev/null || true
done

# Free critical ports
if command -v fuser > /dev/null 2>&1; then
    for _port in 2379 6379 7670 7671 8081 8082 3000 8265 9010 9011 19530; do
        fuser -k "${_port}/tcp" 2>/dev/null || true
    done
fi

echo "   ✅ Cleanup done"
echo ""

# ==============================================================================
# Step 3: Create new exec directory
# ==============================================================================
_DATE=$(date +%Y_%m_%d)
_IDX=1
while [ -d "$_RAG_BASE_DIR/exec_${_DATE}_${_IDX}" ]; do
    _IDX=$((_IDX + 1))
done
_EXEC_DIR="$_RAG_BASE_DIR/exec_${_DATE}_${_IDX}"

mkdir -p "$_EXEC_DIR/logs"
mkdir -p "$_EXEC_DIR/tmp"
mkdir -p "$_EXEC_DIR/runtime/pids"
mkdir -p "$_EXEC_DIR/runtime/nim-work"
mkdir -p "$_EXEC_DIR/runtime/ingestor-temp"
mkdir -p "$_EXEC_DIR/runtime/ingestor-venv-bin"
mkdir -p "$_EXEC_DIR/runtime/nv-ingest-data"

echo "$_EXEC_DIR" > "$_RAG_BASE_DIR/.current_exec"
echo "=== New session: $(basename $_EXEC_DIR) ==="
echo ""

# ==============================================================================
# Step 4: Load configuration (now reads .current_exec → sets all path vars)
# ==============================================================================
source "$(dirname "$0")/config.sh"

# ==============================================================================
# Healthcheck Functions
# ==============================================================================

wait_for_etcd() {
    local host=$1
    local port=$2
    local attempt=1
    echo "   ⏳ Waiting for etcd to be ready..."
    while true; do
        if curl -s "http://${host}:${port}/health" > /dev/null 2>&1; then
            echo "   ✅ etcd is ready (${attempt}s)"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
}

wait_for_minio() {
    local host=$1
    local port=$2
    local attempt=1
    echo "   ⏳ Waiting for MinIO to be ready..."
    while true; do
        if curl -s "http://${host}:${port}/minio/health/live" > /dev/null 2>&1; then
            echo "   ✅ MinIO is ready (${attempt}s)"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
}

wait_for_milvus() {
    local host=$1
    local port=$2
    local pid=$3
    local attempt=1
    echo "   ⏳ Waiting for Milvus to be ready (may take 30-90s)..."
    while true; do
        if ! ps -p "$pid" > /dev/null 2>&1; then
            echo "   ❌ Milvus process died (PID $pid)"
            echo "   Check logs: $RAG_LOGS_DIR/milvus.log"
            return 1
        fi
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
            echo "   ✅ Milvus is ready ($((attempt * 2))s)"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
}

echo "=== Starting RAG Infrastructure Services ==="
echo ""

# ==============================================================================
# 1. Start etcd (required by Milvus)
# ==============================================================================
echo "[1/3] Starting etcd..."

singularity exec \
  --bind $RAG_ETCD_DATA_DIR:/etcd-data \
  $RAG_IMAGES_DIR/etcd.sif \
  /usr/local/bin/etcd \
    --data-dir=/etcd-data \
    --listen-client-urls=http://0.0.0.0:$ETCD_PORT \
    --advertise-client-urls=http://$ETCD_HOST:$ETCD_PORT \
    > $RAG_LOGS_DIR/etcd.log 2>&1 &

ETCD_PID=$!
echo $ETCD_PID > $RAG_RUNTIME_DIR/pids/etcd.pid

sleep 1
if ps -p $ETCD_PID > /dev/null; then
    echo "   ✅ etcd started (port $ETCD_PORT, PID $ETCD_PID)"
else
    echo "   ❌ etcd failed to start"
    echo "   Check logs: tail -20 $RAG_LOGS_DIR/etcd.log"
    exit 1
fi
wait_for_etcd $ETCD_HOST $ETCD_PORT

# ==============================================================================
# 2. Start MinIO (object storage)
# ==============================================================================
echo "[2/3] Starting MinIO..."

singularity exec \
  --env MINIO_ROOT_USER=$MINIO_ROOT_USER \
  --env MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD \
  --bind $RAG_MINIO_DATA_DIR:/data \
  $RAG_IMAGES_DIR/minio.sif \
  minio server /data \
    --console-address :$MINIO_CONSOLE_PORT \
    --address :$MINIO_PORT \
    > $RAG_LOGS_DIR/minio.log 2>&1 &

MINIO_PID=$!
echo $MINIO_PID > $RAG_RUNTIME_DIR/pids/minio.pid

sleep 1
if ps -p $MINIO_PID > /dev/null; then
    echo "   ✅ MinIO started (port $MINIO_PORT, PID $MINIO_PID)"
else
    echo "   ❌ MinIO failed to start"
    echo "   Check logs: tail -20 $RAG_LOGS_DIR/minio.log"
    exit 1
fi
wait_for_minio $MINIO_HOST $MINIO_PORT

# ==============================================================================
# 3. Start Milvus (vector database)
# ==============================================================================
echo "[3/3] Starting Milvus standalone..."

# Extract default Milvus configs from SIF on first use (persists in db/)
if [ ! -f "$RAG_MILVUS_CONFIG_DIR/milvus.yaml" ]; then
    echo "   Setting up Milvus config (one-time)..."
    singularity exec $RAG_IMAGES_DIR/milvus.sif \
      tar czf /tmp/milvus-configs.tar.gz -C /milvus configs/ > /dev/null 2>&1
    tar xzf /tmp/milvus-configs.tar.gz -C "$RAG_DB_DIR" > /dev/null 2>&1
    mv "$RAG_DB_DIR/configs" "$RAG_MILVUS_CONFIG_DIR"
    rm -f /tmp/milvus-configs.tar.gz
    cp "$(dirname "$0")/../configs/milvus.yaml" "$RAG_MILVUS_CONFIG_DIR/milvus.yaml"
    echo "   ✅ Milvus config ready"
fi

# Ensure glog.conf exists — required by Knowhere (C++ glog) at IndexNode init.
# The SIF's /milvus/configs/ does not ship glog.conf; an empty file is valid.
touch "$RAG_MILVUS_CONFIG_DIR/glog.conf"

singularity exec \
  --nv \
  --env ETCD_ENDPOINTS=$ETCD_HOST:$ETCD_PORT \
  --env MINIO_ADDRESS=$MINIO_HOST:$MINIO_PORT \
  --env "KNOWHERE_GPU_MEM_POOL_SIZE=2048;4096" \
  --bind $RAG_MILVUS_DATA_DIR:/var/lib/milvus \
  --bind $RAG_MILVUS_CONFIG_DIR:/milvus/configs \
  $RAG_IMAGES_DIR/milvus.sif \
  bash -c "cd /milvus && milvus run standalone" \
    > $RAG_LOGS_DIR/milvus.log 2>&1 &

MILVUS_PID=$!
echo $MILVUS_PID > $RAG_RUNTIME_DIR/pids/milvus.pid

sleep 1
if ps -p $MILVUS_PID > /dev/null; then
    echo "   ✅ Milvus started (port $MILVUS_PORT, PID $MILVUS_PID)"
else
    echo "   ❌ Milvus failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/milvus.log"
    exit 1
fi
wait_for_milvus $MILVUS_HOST $MILVUS_PORT $MILVUS_PID

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=== Infrastructure Started ==="
echo "✅ etcd:   $ETCD_HOST:$ETCD_PORT   (PID $ETCD_PID)"
echo "✅ MinIO:  $MINIO_HOST:$MINIO_PORT   (PID $MINIO_PID)"
echo "✅ Milvus: $MILVUS_HOST:$MILVUS_PORT  (PID $MILVUS_PID)"
echo ""
echo "Session: $(basename $RAG_EXEC_DIR)"
echo "Logs:    $RAG_LOGS_DIR/"
echo "DB:      $RAG_DB_DIR/"
echo ""
echo "Next: Run 03-start-redis.sh"
