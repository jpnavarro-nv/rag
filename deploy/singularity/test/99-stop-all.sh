#!/bin/bash
# Stop all RAG Singularity processes and instances

echo "=== Stopping All RAG Services ==="
echo ""

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Function to stop Singularity instance
stop_instance() {
    local instance_name=$1
    echo "Stopping instance $instance_name..."
    if singularity instance list | grep -q "^${instance_name}"; then
        singularity instance stop "$instance_name"
        echo "   ✅ $instance_name stopped"
    else
        echo "   ⊘  $instance_name not running"
    fi
}

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

echo "=== Stopping Application Servers ==="
stop_process "rag-server"
stop_process "ingestor-server"

echo ""
echo "=== Stopping Ingestion Services ==="
stop_process "nv-ingest"
stop_process "redis"

echo ""
echo "=== Stopping NIM Instances ==="
stop_instance "nim-nemoretriever-embedding"
stop_instance "nim-nemoretriever-ranking"
stop_instance "nim-nim-llm"
stop_instance "nim-vlm"
stop_instance "nim-page-elements"
stop_instance "nim-graphic-elements"
stop_instance "nim-table-structure"
stop_instance "nim-paddle-ocr"

echo ""
echo "=== Stopping Infrastructure ==="
stop_process "milvus"
stop_process "minio"
stop_process "etcd"

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "To restart:"
echo "  Full stack: ./01-start-infrastructure.sh && ./03-start-redis.sh && ./04-start-nim-models.sh && ./05-wait-nim-models.sh && ./06-start-nv-ingest-ms.sh && ./07-start-ingest-server.sh && ./08-start-rag-server.sh"
echo "  Query-only: ./01-start-infrastructure.sh && ./08-start-rag-server.sh"
