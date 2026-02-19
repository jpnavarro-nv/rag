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
# NIM_HTTP_API_PORT is for Triton-based NIMs only - ignored by this VLM container.
# NIM_SERVER_PORT sets the argparse default but is NOT forwarded into cli_args/os.execvpe.
# The only reliable fix: pass --port directly to start_server.sh.
# start_server.sh calls: python3 -m nim_llm_sdk.entrypoints.launch "$@"
# The "$@" forwards --port into cli_args -> api_server.py receives --port.
# In Docker: port mapping 1977:8000 exists; internal port is always 8000.
# In Singularity (host network): no port mapping, VLM must bind on host port directly.
VLM_PORT=1977

echo "=== Testing VLM NIM in Isolation ==="
echo ""
echo "Configuration:"
echo "  NGC_API_KEY:   ${NGC_API_KEY:0:10}...${NGC_API_KEY: -4}"
echo "  Images dir:    $RAG_IMAGES_DIR"
echo "  GPU:           3"
echo "  Port:          $VLM_PORT (passed as --port to start_server.sh)"
echo ""

# Check if VLM image exists
if [ ! -f "$RAG_IMAGES_DIR/vlm.sif" ]; then
    echo "❌ ERROR: VLM image not found at $RAG_IMAGES_DIR/vlm.sif"
    exit 1
fi

echo "✅ VLM image found"
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

# Start VLM with exec (not instance) to see full output.
# --port $VLM_PORT is passed directly to start_server.sh, which forwards it via "$@"
# to nim_llm_sdk.entrypoints.launch -> cli_args -> api_server.py --port 1977.
singularity exec \
  --cleanenv \
  --nv \
  --bind "$NIM_CACHE_DIR:/opt/nim/.cache" \
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
  /opt/nim/start_server.sh --port $VLM_PORT \
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
echo "Health URL: http://localhost:$VLM_PORT/v1/health/ready"
echo ""

# Check health endpoint every 10 seconds
for i in {1..60}; do
    sleep 10
    echo -n "[$i/60] $(date +%H:%M:%S) - "

    if curl -s -f "http://localhost:$VLM_PORT/v1/health/ready" >/dev/null 2>&1; then
        echo "✅ VLM is READY on port $VLM_PORT!"
        echo ""
        echo "=== VLM Test Successful ==="
        echo ""
        echo "=== Last 50 lines of log ==="
        tail -50 "$RAG_LOGS_DIR/vlm-test.log"
        echo ""
        echo "Test the VLM:"
        echo "  curl http://localhost:$VLM_PORT/v1/models"
        echo ""
        echo "Stop VLM:"
        echo "  kill \$(cat $RAG_RUNTIME_DIR/pids/vlm-test.pid)"
        echo "  rm -f $RAG_RUNTIME_DIR/pids/vlm-test.pid"
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
