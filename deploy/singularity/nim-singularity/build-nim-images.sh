#!/bin/bash
# Pull LLM NIM images for standalone testing.
# Images are pulled sequentially; already-existing SIFs are skipped.
#
# Usage:
#   export NGC_API_KEY="nvapi-..."
#   export NIM_BASE_DIR="/path/to/nim-workdir"
#   ./build-nim-images.sh

set -e

# ==============================================================================
# Version pinning
# ==============================================================================
NEMOTRON_49B_VERSION="1.14.0"
QWEN3_122B_VERSION="latest"
GPT_OSS_120B_VERSION="latest"
NEMOTRON3_120B_VERSION="latest"

# ==============================================================================
# Directory setup (self-contained — no external sources)
# ==============================================================================
export NIM_BASE_DIR="${NIM_BASE_DIR:?Set NIM_BASE_DIR before running}"
export NIM_IMAGES_DIR="$NIM_BASE_DIR/containers/images"
export SINGULARITY_CACHEDIR="$NIM_BASE_DIR/containers/cache"

mkdir -p "$NIM_IMAGES_DIR"
mkdir -p "$SINGULARITY_CACHEDIR"

echo "=== LLM NIM Image Pull ==="
echo ""
echo "NIM_BASE_DIR:      $NIM_BASE_DIR"
echo "Output directory:  $NIM_IMAGES_DIR"
echo "Singularity cache: $SINGULARITY_CACHEDIR"
echo ""

# ==============================================================================
# NGC authentication
# ==============================================================================
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ NGC_API_KEY not set. Export it before running:"
    echo "   export NGC_API_KEY='nvapi-...'"
    exit 1
fi

export SINGULARITY_DOCKER_USERNAME='$oauthtoken'
export SINGULARITY_DOCKER_PASSWORD="$NGC_API_KEY"
echo "✅ NGC auth configured"
echo ""

# ==============================================================================
# Helper
# ==============================================================================
SUCCESS=0
FAILED=0

pull_image() {
    local docker_uri=$1
    local sif_name=$2
    local description=$3

    echo "[$sif_name] $description"

    if [ -f "$NIM_IMAGES_DIR/$sif_name" ]; then
        echo "    ✅ Already exists — skipped"
        ls -lh "$NIM_IMAGES_DIR/$sif_name" | awk '{print "       Size:", $5}'
        SUCCESS=$((SUCCESS + 1))
    else
        echo "    Pulling from $docker_uri..."
        if singularity pull "$NIM_IMAGES_DIR/$sif_name" "docker://$docker_uri"; then
            echo "    ✅ Pulled successfully"
            ls -lh "$NIM_IMAGES_DIR/$sif_name" | awk '{print "       Size:", $5}'
            SUCCESS=$((SUCCESS + 1))
        else
            echo "    ❌ Pull failed"
            FAILED=$((FAILED + 1))
        fi
    fi
    echo ""
}

# ==============================================================================
# Pull LLM NIMs (sequential)
# ==============================================================================
pull_image \
    "nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:$NEMOTRON_49B_VERSION" \
    "nim-llm-nemotron-49b.sif" \
    "Nemotron Super 49B v$NEMOTRON_49B_VERSION"

pull_image \
    "nvcr.io/nim/qwen/qwen3.5-122b-a10b:$QWEN3_122B_VERSION" \
    "nim-llm-qwen3-122b.sif" \
    "Qwen 3.5 122B-A10B ($QWEN3_122B_VERSION)"

pull_image \
    "nvcr.io/nim/openai/gpt-oss-120b:$GPT_OSS_120B_VERSION" \
    "nim-llm-gpt-oss-120b.sif" \
    "GPT-OSS 120B ($GPT_OSS_120B_VERSION)"

pull_image \
    "nvcr.io/nim/nvidia/nemotron-3-super-120b-a12b:$NEMOTRON3_120B_VERSION" \
    "nim-llm-nemotron3-120b.sif" \
    "Nemotron-3 Super 120B-A12B ($NEMOTRON3_120B_VERSION)"

# ==============================================================================
# Summary
# ==============================================================================
echo "=== Summary ==="
echo "✅ Success: $SUCCESS"
echo "❌ Failed:  $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "All images ready at: $NIM_IMAGES_DIR"
    echo ""
    echo "Next step: ./run-nim.sh"
else
    echo "⚠️  Some images failed. Check errors above."
    exit 1
fi
