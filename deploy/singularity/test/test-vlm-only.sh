#!/bin/bash
# Test VLM NIM in isolation
set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ ERROR: NGC_API_KEY not set"
    exit 1
fi

# VLM NIM port behavior:
# The nim_llm_sdk/vLLM stack reads the port ONLY from the --port CLI argument.
# NIM_SERVER_PORT and NIM_HTTP_API_PORT are not translated to --port by launch.py
# in this image version (confirmed: launch command shows no --port in the log).
# The container always binds internally to port 8000.
#
# In Docker: port mapping 1977:8000 makes VLM reachable on 1977.
# In Singularity (host network): no port mapping exists. VLM is on host:8000.
#
# For full-stack integration where other services expect port 1977, we use socat
# to proxy 1977 -> 8000 on the host. See SOCAT_PROXY below.
VLM_INTERNAL_PORT=8000
VLM_EXTERNAL_PORT=1977

echo "=== Testing VLM NIM in Isolation ==="
echo ""
echo "Configuration:"
echo "  NGC_API_KEY:   ${NGC_API_KEY:0:10}...${NGC_API_KEY: -4}"
echo "  Images dir:    $RAG_IMAGES_DIR"
echo "  GPU:           3"
echo "  Internal port: $VLM_INTERNAL_PORT (VLM always binds here)"
echo "  External port: $VLM_EXTERNAL_PORT (socat proxy -> $VLM_INTERNAL_PORT)"
echo ""

# Check if VLM image exists
if [ ! -f "$RAG_IMAGES_DIR/vlm.sif" ]; then
    echo "❌ ERROR: VLM image not found at $RAG_IMAGES_DIR/vlm.sif"
    exit 1
fi

echo "✅ VLM image found"
echo ""

# Check socat availability (needed for port proxy)
SOCAT_AVAILABLE=false
if command -v socat &> /dev/null; then
    SOCAT_AVAILABLE=true
    echo "✅ socat available (port proxy 1977->8000 will be set up)"
else
    echo "⚠️  socat not found - VLM will only be accessible on port $VLM_INTERNAL_PORT"
    echo "   Install with: apt-get install socat  OR  module load socat"
fi
echo ""

# Kill any existing VLM process
if [ -f "$RAG_RUNTIME_DIR/pids/vlm-test.pid" ]; then
    OLD_PID=$(cat "$RAG_RUNTIME_DIR/pids/vlm-test.pid")
    if ps -p $OLD_PID > /dev/null 2>&1; then
        echo "Stopping existing VLM process (PID $OLD_PID)..."
        kill $OLD_PID
        sleep 2
    fi
    rm -f "$RAG_RUNTIME_DIR/pids/vlm-test.pid"
fi

# Kill any existing socat proxy
if [ -f "$RAG_RUNTIME_DIR/pids/vlm-socat.pid" ]; then
    OLD_PID=$(cat "$RAG_RUNTIME_DIR/pids/vlm-socat.pid")
    if ps -p $OLD_PID > /dev/null 2>&1; then
        echo "Stopping existing socat proxy (PID $OLD_PID)..."
        kill $OLD_PID 2>/dev/null || true
    fi
    rm -f "$RAG_RUNTIME_DIR/pids/vlm-socat.pid"
fi

# Clean log
> "$RAG_LOGS_DIR/vlm-test.log"

echo "Starting VLM NIM server..."
echo "  This will download the model on first run (~16GB)"
echo "  Log: $RAG_LOGS_DIR/vlm-test.log"
echo ""

# Create NIM cache directory (writable)
NIM_CACHE_DIR="$RAG_BASE_DIR/models/vlm-cache"
mkdir -p "$NIM_CACHE_DIR"
chmod 755 "$NIM_CACHE_DIR"

echo "Cache directory: $NIM_CACHE_DIR"
echo ""

# Start VLM with exec (not instance) to see full output
# Note: NIM_SERVER_PORT is passed but may not be effective in this image version.
# The server will bind to port 8000. Use socat proxy for external port 1977.
singularity exec \
  --cleanenv \
  --nv \
  --bind "$NIM_CACHE_DIR:/opt/nim/.cache" \
  --env NIM_SERVER_PORT=$VLM_INTERNAL_PORT \
  --env NIM_TENSOR_PARALLEL_SIZE=1 \
  --env NIM_PIPELINE_PARALLEL_SIZE=1 \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env NIM_CACHE_PATH=/opt/nim/.cache \
  --env CUDA_VISIBLE_DEVICES=3 \
  --env OMPI_MCA_pmix=^all \
  --env OMPI_MCA_pml=ob1 \
  --env PMIX_MCA_gds=^ds12,ds21 \
  --env PMIX_MCA_psec=^munge \
  "$RAG_IMAGES_DIR/vlm.sif" \
  /opt/nim/start_server.sh \
  > "$RAG_LOGS_DIR/vlm-test.log" 2>&1 &

VLM_PID=$!
echo $VLM_PID > "$RAG_RUNTIME_DIR/pids/vlm-test.pid"

# Wait a moment and check if process started
sleep 3
if ps -p $VLM_PID > /dev/null 2>&1; then
    echo "✅ VLM server started (PID $VLM_PID)"
else
    echo "❌ VLM failed to start"
    echo ""
    echo "=== Log output ==="
    cat "$RAG_LOGS_DIR/vlm-test.log"
    exit 1
fi

echo ""
echo "=== Waiting for VLM startup (max 10 min) ==="
echo "Health URL: http://localhost:$VLM_INTERNAL_PORT/v1/health/ready"
echo ""

# Check health endpoint every 10 seconds on the internal port
for i in {1..60}; do
    sleep 10
    echo -n "[$i/60] $(date +%H:%M:%S) - "

    if curl -s -f "http://localhost:$VLM_INTERNAL_PORT/v1/health/ready" >/dev/null 2>&1; then
        echo "✅ VLM is READY on port $VLM_INTERNAL_PORT!"
        echo ""

        # Start socat proxy 1977 -> 8000 if available
        if [ "$SOCAT_AVAILABLE" = "true" ]; then
            socat TCP-LISTEN:$VLM_EXTERNAL_PORT,reuseaddr,fork TCP:localhost:$VLM_INTERNAL_PORT \
              > "$RAG_LOGS_DIR/vlm-socat.log" 2>&1 &
            SOCAT_PID=$!
            echo $SOCAT_PID > "$RAG_RUNTIME_DIR/pids/vlm-socat.pid"
            sleep 1
            if ps -p $SOCAT_PID > /dev/null 2>&1; then
                echo "✅ socat proxy started: localhost:$VLM_EXTERNAL_PORT -> localhost:$VLM_INTERNAL_PORT (PID $SOCAT_PID)"
            else
                echo "⚠️  socat proxy failed to start (check port $VLM_EXTERNAL_PORT not in use)"
            fi
        fi

        echo ""
        echo "=== VLM Test Successful ==="
        echo ""
        echo "=== Last 50 lines of log ==="
        tail -50 "$RAG_LOGS_DIR/vlm-test.log"
        echo ""
        echo "Test the VLM:"
        echo "  curl http://localhost:$VLM_INTERNAL_PORT/v1/models"
        if [ "$SOCAT_AVAILABLE" = "true" ]; then
            echo "  curl http://localhost:$VLM_EXTERNAL_PORT/v1/models  (via socat proxy)"
        fi
        echo ""
        echo "Stop VLM + proxy:"
        echo "  kill \$(cat $RAG_RUNTIME_DIR/pids/vlm-test.pid)"
        echo "  kill \$(cat $RAG_RUNTIME_DIR/pids/vlm-socat.pid) 2>/dev/null || true"
        echo "  rm -f $RAG_RUNTIME_DIR/pids/vlm-test.pid $RAG_RUNTIME_DIR/pids/vlm-socat.pid"
        echo ""
        exit 0
    else
        echo "⏳ Still loading..."
    fi
done

echo ""
echo "❌ VLM did not become ready after 10 minutes"
echo ""
echo "=== Full log output for debug ==="
echo "════════════════════════════════════════════════════════════════════"
cat "$RAG_LOGS_DIR/vlm-test.log"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "=== GPU Status ==="
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv
echo ""
echo "Process still running. To stop:"
echo "  kill \$(cat $RAG_RUNTIME_DIR/pids/vlm-test.pid)"
echo "  rm $RAG_RUNTIME_DIR/pids/vlm-test.pid"
echo ""
exit 1
