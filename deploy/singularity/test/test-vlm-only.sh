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

echo "=== Testing VLM NIM in Isolation ==="
echo ""
echo "Configuration:"
echo "  NGC_API_KEY: ${NGC_API_KEY:0:10}...${NGC_API_KEY: -4}"
echo "  Images dir: $RAG_IMAGES_DIR"
echo "  GPU: 3"
echo "  Port: 1977 (matching Docker Compose)"
echo ""

# Check if VLM image exists
if [ ! -f "$RAG_IMAGES_DIR/vlm.sif" ]; then
    echo "❌ ERROR: VLM image not found at $RAG_IMAGES_DIR/vlm.sif"
    exit 1
fi

echo "✅ VLM image found"
echo ""

# Check for existing VLM Singularity instances and stop them
echo "Checking for existing VLM instances..."
EXISTING_INSTANCES=$(singularity instance list | grep -E "vlm|nemotron.*vl" | awk '{print $1}')
if [ -n "$EXISTING_INSTANCES" ]; then
    echo "Found existing VLM instances, stopping them..."
    for instance in $EXISTING_INSTANCES; do
        echo "  Stopping instance: $instance"
        singularity instance stop $instance
    done
    sleep 2
fi

# Kill any existing process
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

# Check GPU memory before starting
echo "=== GPU Status Before Start ==="
nvidia-smi --query-gpu=index,name,memory.used,memory.free,memory.total --format=csv
echo ""

# Check if GPU 3 has enough free memory (need ~10GB for engine build)
GPU_FREE_MB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i 3)
GPU_TOTAL_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 3)
GPU_FREE_GB=$((GPU_FREE_MB / 1024))
GPU_TOTAL_GB=$((GPU_TOTAL_MB / 1024))

echo "GPU 3 Memory: ${GPU_FREE_GB}GB free / ${GPU_TOTAL_GB}GB total"

if [ $GPU_FREE_MB -lt 10240 ]; then
    echo ""
    echo "⚠️  WARNING: GPU 3 has less than 10GB free memory"
    echo "   TensorRT engine build may fail with CUDA OOM error"
    echo "   Free memory: ${GPU_FREE_GB}GB"
    echo ""
    echo "To free GPU memory, check running processes:"
    echo "  nvidia-smi"
    echo "  fuser -v /dev/nvidia3"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
echo ""

# Export APPTAINERENV_ variables to override container defaults
# Port 1977 matches Docker Compose configuration (1977:8000)
export APPTAINERENV_NIM_HTTP_API_PORT=1977
export APPTAINERENV_NIM_TENSOR_PARALLEL_SIZE=1
export APPTAINERENV_NIM_PIPELINE_PARALLEL_SIZE=1
export APPTAINERENV_NGC_API_KEY=$NGC_API_KEY
export APPTAINERENV_NVIDIA_API_KEY=$NGC_API_KEY
export APPTAINERENV_NIM_CACHE_PATH=/opt/nim/.cache
export APPTAINERENV_CUDA_VISIBLE_DEVICES=3

# Reduce GPU memory utilization to 0.7 for engine build (default 0.9 is too high)
# This leaves more memory for TensorRT engine compilation
export APPTAINERENV_NIM_GPU_MEMORY_UTILIZATION=0.7

# Disable MPI/PMIx for single-GPU deployment
export APPTAINERENV_OMPI_MCA_pmix=^all
export APPTAINERENV_OMPI_MCA_pml=ob1
export APPTAINERENV_PMIX_MCA_gds=^ds12,ds21
export APPTAINERENV_PMIX_MCA_psec=^munge

# Start VLM with exec (not instance) to see full output
# Using --cleanenv to remove SLURM vars, then SINGULARITYENV_ to set ours
singularity exec \
  --cleanenv \
  --nv \
  --bind "$NIM_CACHE_DIR:/opt/nim/.cache" \
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
echo "Health URL: http://localhost:1977/v1/health/ready"
echo ""

# Check health endpoint every 10 seconds
for i in {1..60}; do
    sleep 10
    echo -n "[$i/60] $(date +%H:%M:%S) - "

    if curl -s -f "http://localhost:1977/v1/health/ready" >/dev/null 2>&1; then
        echo "✅ VLM is READY!"
        echo ""
        echo "=== VLM Test Successful ==="
        echo ""
        echo "=== Last 50 lines of log ==="
        tail -50 "$RAG_LOGS_DIR/vlm-test.log"
        echo ""
        echo "Test the VLM:"
        echo "  curl http://localhost:1977/v1/models"
        echo ""
        echo "Stop VLM:"
        echo "  kill $(cat $RAG_RUNTIME_DIR/pids/vlm-test.pid)"
        echo "  rm $RAG_RUNTIME_DIR/pids/vlm-test.pid"
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
echo "  kill $(cat $RAG_RUNTIME_DIR/pids/vlm-test.pid)"
echo "  rm $RAG_RUNTIME_DIR/pids/vlm-test.pid"
echo ""
exit 1
