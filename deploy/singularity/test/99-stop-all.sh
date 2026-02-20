#!/bin/bash
# Stop all RAG Singularity processes, subprocesses, and free all ports.
#
# Strategy:
#   1. SIGTERM to saved PID + pkill -P to kill direct children
#   2. Wait up to 8 s for graceful shutdown; SIGKILL if still alive
#   3. fuser -k PORT/tcp as final sweep for any orphan port holders
#   4. Stop any stray Apptainer instances and remove PID files

echo "=== Stopping All RAG Services ==="
echo ""

# Load configuration (RAG_RUNTIME_DIR, RAG_LOGS_DIR, ports, etc.)
source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

# Ports defined in individual scripts (not in nim-lib.sh)
REDIS_PORT=${REDIS_PORT:-6379}
NVINGEST_PORT=${NVINGEST_PORT:-7670}
NVINGEST_BROKER_PORT=${NVINGEST_BROKER_PORT:-7671}
INGESTOR_PORT=${INGESTOR_PORT:-8082}
RAG_SERVER_PORT=${RAG_SERVER_PORT:-8081}

# ==============================================================================
# stop_process NAME
#   Kills the saved PID and its direct children (singularity subprocesses).
#   Removes the PID file regardless of outcome.
# ==============================================================================
stop_process() {
    local name=$1
    local pid_file="$RAG_RUNTIME_DIR/pids/${name}.pid"

    if [ ! -f "$pid_file" ]; then
        echo "   ⊘  $name — no PID file"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")
    rm -f "$pid_file"

    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "   ⊘  $name already stopped (stale PID $pid)"
        return 0
    fi

    echo "   Stopping $name (PID $pid)..."

    # Terminate the launcher and its direct children (container init, workers)
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true

    # Wait up to 8 s for graceful exit
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        if ! ps -p "$pid" > /dev/null 2>&1; then
            echo "   ✅ $name stopped"
            return 0
        fi
    done

    # Force kill — process and its surviving children
    echo "   ⚠️  $name still alive after 8 s — force killing..."
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -P "$pid" 2>/dev/null || true
    sleep 1

    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "   ✅ $name force-killed"
    else
        echo "   ❌ $name could not be killed (PID $pid)"
    fi
}

# ==============================================================================
# free_port LABEL PORT
#   Kills any process still holding the given TCP port.
#   Uses fuser if available; falls back to ss + kill.
# ==============================================================================
free_port() {
    local label=$1
    local port=$2

    if command -v fuser > /dev/null 2>&1; then
        local holders
        holders=$(fuser "${port}/tcp" 2>/dev/null || true)
        if [ -n "$holders" ]; then
            echo "   Releasing $label (port $port) — orphan PIDs:$holders"
            fuser -k "${port}/tcp" 2>/dev/null || true
        fi
        return 0
    fi

    # Fallback: ss + xargs kill
    if command -v ss > /dev/null 2>&1; then
        local pids
        pids=$(ss -tlnp "sport = :${port}" 2>/dev/null \
               | grep -oP 'pid=\K[0-9]+' | sort -u || true)
        if [ -n "$pids" ]; then
            echo "   Releasing $label (port $port) — orphan PIDs: $pids"
            echo "$pids" | xargs -r kill -9 2>/dev/null || true
        fi
    fi
}

# ==============================================================================
# Tear-down order: dependents first, foundations last
# ==============================================================================

echo "=== [1/6] Stopping Application Servers ==="
stop_process "rag-frontend"
stop_process "rag-server"
stop_process "ingestor-server"

echo ""
echo "=== [2/6] Stopping Ingestion Services ==="
stop_process "nv-ingest"

# Ray launches grandchild processes (raylet, gcs_server, plasma_store, dashboard, workers)
# that are NOT direct children of the Singularity launcher, so pkill -P misses them.
# Kill them explicitly by name.
_ray_killed=0
for _ray_pat in "raylet" "ray::" "gcs_server" "plasma_store_server" "dashboard_agent" "ray/dashboard"; do
    if pkill -f "$_ray_pat" 2>/dev/null; then
        _ray_killed=1
    fi
done
if [ $_ray_killed -eq 1 ]; then
    sleep 2
    echo "   ✅ Ray sub-processes cleared"
else
    echo "   ⊘  No Ray sub-processes found"
fi

stop_process "redis"

echo ""
echo "=== [3/6] Stopping NIM Processes ==="
stop_process "vlm"
stop_process "nim-llm"
stop_process "nemoretriever-embedding"
stop_process "nemoretriever-ranking"
stop_process "page-elements"
stop_process "graphic-elements"
stop_process "table-structure"
stop_process "paddle-ocr"

echo ""
echo "=== [4/6] Stopping Infrastructure ==="
stop_process "milvus"
stop_process "minio"
stop_process "etcd"

echo ""
echo "=== [5/6] Cleaning Up Stray Instances & PID Files ==="

# Stop any Apptainer/Singularity instances started via 'instance start'
# (our scripts don't use them, but belt-and-suspenders for manual runs)
# Note: check 'instance list' first — 'instance stop --all' prints usage
# to stdout (not stderr) when no instances exist on some Apptainer versions,
# bypassing 2>/dev/null. Only attempt stop when instances are actually running.
_INSTANCE_CMD=""
if command -v apptainer > /dev/null 2>&1; then
    _INSTANCE_CMD="apptainer"
elif command -v singularity > /dev/null 2>&1; then
    _INSTANCE_CMD="singularity"
fi

if [ -n "$_INSTANCE_CMD" ]; then
    _INSTANCES=$($_INSTANCE_CMD instance list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$' || true)
    if [ -n "$_INSTANCES" ]; then
        $_INSTANCE_CMD instance stop --all >/dev/null 2>&1 || true
        echo "   ✅ $_INSTANCE_CMD instances cleared"
    else
        echo "   ⊘  No $_INSTANCE_CMD instances running"
    fi
fi

# Remove any remaining PID files (handles services added later without updating this script)
orphan_pids=$(ls "$RAG_RUNTIME_DIR/pids/"*.pid 2>/dev/null || true)
if [ -n "$orphan_pids" ]; then
    echo "   Removing orphan PID files:"
    for f in $orphan_pids; do
        echo "      $f"
        rm -f "$f"
    done
fi

echo ""
echo "=== [6/6] Releasing Ports ==="

# Application layer
FRONTEND_PORT=${FRONTEND_PORT:-3000}
free_port "Frontend"              $FRONTEND_PORT
free_port "RAG Server"            $RAG_SERVER_PORT
free_port "Ingestor"              $INGESTOR_PORT

# Ingestion layer
free_port "NV-Ingest HTTP"        $NVINGEST_PORT
free_port "NV-Ingest Broker"      $NVINGEST_BROKER_PORT
free_port "Ray Dashboard"         8265
free_port "Redis"                 $REDIS_PORT

# NIMs — LLM/VLM family (nim_llm_sdk / vLLM)
free_port "VLM"                   $VLM_PORT
free_port "LLM"                   $LLM_PORT

# NIMs — Triton family (HTTP + gRPC = PORT and PORT+1)
free_port "Embedding HTTP"        $EMBEDDING_PORT
free_port "Embedding gRPC"        $((EMBEDDING_PORT + 1))
free_port "Ranking HTTP"          $RANKING_PORT
free_port "Ranking gRPC"          $((RANKING_PORT + 1))
free_port "Page-Elements HTTP"    $PAGE_ELEMENTS_PORT
free_port "Page-Elements gRPC"    $((PAGE_ELEMENTS_PORT + 1))
free_port "Graphic-Elements HTTP" $GRAPHIC_ELEMENTS_PORT
free_port "Graphic-Elements gRPC" $((GRAPHIC_ELEMENTS_PORT + 1))
free_port "Table-Structure HTTP"  $TABLE_STRUCTURE_PORT
free_port "Table-Structure gRPC"  $((TABLE_STRUCTURE_PORT + 1))
free_port "PaddleOCR HTTP"        $PADDLE_OCR_PORT
free_port "PaddleOCR gRPC"        $((PADDLE_OCR_PORT + 1))

# Infrastructure
free_port "Milvus"                $MILVUS_PORT
free_port "MinIO API"             $MINIO_PORT
free_port "MinIO Console"         $MINIO_CONSOLE_PORT
free_port "etcd"                  $ETCD_PORT

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "To restart:"
echo "  Full stack:  ./01-start-infrastructure.sh && ./03-start-redis.sh && ./04-start-nim-models.sh && ./05-wait-nim-models.sh && ./06-start-nv-ingest-ms.sh && ./07-start-ingest-server.sh && ./08-start-rag-server.sh && ./09-start-frontend.sh"
echo "  Query-only:  ./01-start-infrastructure.sh && ./08-start-rag-server.sh && ./09-start-frontend.sh"
