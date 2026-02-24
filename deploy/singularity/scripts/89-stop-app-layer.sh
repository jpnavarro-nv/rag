#!/bin/bash
# Stop application-layer services (scripts 06–09) without touching NIMs or infrastructure.
#
# Stops: NV-Ingest (06), Ingestor Server (07), RAG Server (08), Frontend (09)
# Keeps: NIMs (04), Redis (03), Milvus/MinIO/etcd (01)
#
# Use this to quickly restart the app layer during development without
# waiting for NIMs to reload.
#
# Strategy:
#   1. SIGTERM to saved PID + pkill -P to kill direct children
#   2. Wait up to 8 s for graceful shutdown; SIGKILL if still alive
#   3. fuser -k PORT/tcp as final sweep for any orphan port holders
#   4. Stop any stray Apptainer instances and remove PID files

echo "=== Stopping App-Layer Services (06–09) ==="
echo ""

# Load configuration (RAG_RUNTIME_DIR, RAG_LOGS_DIR, ports, etc.)
source "$(dirname "$0")/00-config.sh"

# Ports defined in individual scripts (not in nim-lib.sh)
NVINGEST_PORT=${NVINGEST_PORT:-7670}
NVINGEST_BROKER_PORT=${NVINGEST_BROKER_PORT:-7671}
INGESTOR_PORT=${INGESTOR_PORT:-8082}
RAG_SERVER_PORT=${RAG_SERVER_PORT:-8081}
FRONTEND_PORT=${FRONTEND_PORT:-3000}

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
# Tear-down order: dependents first, then ingestion
# ==============================================================================

echo "=== [1/4] Stopping Frontend & Servers ==="
stop_process "rag-frontend"
stop_process "rag-server"
stop_process "ingestor-server"

echo ""
echo "=== [2/4] Stopping NV-Ingest ==="
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

echo ""
echo "=== [3/4] Cleaning Up Stray Instances & PID Files ==="

# Stop any Apptainer/Singularity instances started via 'instance start'
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

# Remove any remaining PID files for app-layer services
for _name in rag-frontend rag-server ingestor-server nv-ingest; do
    _f="$RAG_RUNTIME_DIR/pids/${_name}.pid"
    if [ -f "$_f" ]; then
        echo "   Removing orphan PID file: $_f"
        rm -f "$_f"
    fi
done

echo ""
echo "=== [4/4] Releasing Ports ==="

free_port "Frontend"         $FRONTEND_PORT
free_port "RAG Server"       $RAG_SERVER_PORT
free_port "Ingestor"         $INGESTOR_PORT
free_port "NV-Ingest HTTP"   $NVINGEST_PORT
free_port "NV-Ingest Broker" $NVINGEST_BROKER_PORT
free_port "Ray Dashboard"    8265

echo ""
echo "=== App Layer Stopped ==="
echo ""
echo "NIMs, Redis, and infrastructure are still running."
echo ""
echo "To restart the app layer:"
echo "  ./06-start-nv-ingest-ms.sh && ./07-start-ingest-server.sh && ./08-start-rag-server.sh && ./09-start-frontend.sh"
