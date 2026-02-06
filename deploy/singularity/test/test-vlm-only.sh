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
echo "  Port: 8997"
echo ""

# Check if VLM image exists
if [ ! -f "$RAG_IMAGES_DIR/vlm.sif" ]; then
    echo "❌ ERROR: VLM image not found at $RAG_IMAGES_DIR/vlm.sif"
    exit 1
fi

echo "✅ VLM image found"
echo ""

# Stop if already running
if singularity instance list | grep -q "^nim-vlm-test"; then
    echo "Stopping existing nim-vlm-test instance..."
    singularity instance stop nim-vlm-test
    sleep 2
fi

# Clean log
> "$RAG_LOGS_DIR/vlm-test.log"

echo "Starting VLM NIM instance..."
echo "  This will download the model on first run (~16GB)"
echo "  Log: $RAG_LOGS_DIR/vlm-test.log"
echo ""

# Start VLM instance
singularity instance start \
  --nv \
  --env CUDA_VISIBLE_DEVICES=3 \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  "$RAG_IMAGES_DIR/vlm.sif" \
  "nim-vlm-test" \
  > "$RAG_LOGS_DIR/vlm-test.log" 2>&1

if singularity instance list | grep -q "^nim-vlm-test"; then
    echo "✅ Instance started"
else
    echo "❌ Instance failed to start"
    exit 1
fi

echo ""
echo "=== Waiting for VLM startup (max 10 min) ==="
echo "Health URL: http://localhost:8997/v1/health/ready"
echo ""

# Check health endpoint every 10 seconds
for i in {1..60}; do
    sleep 10
    echo -n "[$i/60] $(date +%H:%M:%S) - "

    if curl -s -f "http://localhost:8997/v1/health/ready" >/dev/null 2>&1; then
        echo "✅ VLM is READY!"
        echo ""
        echo "=== VLM Test Successful ==="
        echo ""
        echo "=== Last 50 lines of log ==="
        tail -50 "$RAG_LOGS_DIR/vlm-test.log"
        echo ""
        echo "Test the VLM:"
        echo "  curl http://localhost:8997/v1/models"
        echo ""
        echo "Stop VLM:"
        echo "  singularity instance stop nim-vlm-test"
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
echo "Instance still running. To stop:"
echo "  singularity instance stop nim-vlm-test"
echo ""
exit 1
