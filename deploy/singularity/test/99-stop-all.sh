#!/bin/bash
# Stop all RAG Singularity processes

echo "=== Stopping All RAG Services ==="
echo ""

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Function to stop process if running
stop_process() {
    local service_name=$1
    local pid_file="$RAG_RUNTIME_DIR/pids/${service_name}.pid"

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        echo "Stopping $service_name (PID $pid)..."
        if ps -p $pid > /dev/null 2>&1; then
            kill $pid
            sleep 2
            # Force kill if still running
            if ps -p $pid > /dev/null 2>&1; then
                kill -9 $pid 2>/dev/null
            fi
            echo "   ✅ $service_name stopped"
        else
            echo "   ⊘  $service_name already stopped"
        fi
        rm -f "$pid_file"
    else
        echo "   ⊘  $service_name PID file not found"
    fi
}

# Stop services in reverse order
stop_process "rag-server"
stop_process "milvus"
stop_process "minio"
stop_process "etcd"

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "To restart:"
echo "  1. ./01-start-infrastructure.sh"
echo "  2. ./02-test-connectivity.sh"
echo "  3. ./03-start-rag-server.sh"
