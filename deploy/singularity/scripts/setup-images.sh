#!/bin/bash
# Setup all container images for RAG Singularity deployment
# Orchestrates building custom images and pulling pre-built images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to minimal image set
IMAGE_SET="${1:-minimal}"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         RAG Singularity - Image Setup                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Validate image set parameter
if [[ "$IMAGE_SET" != "minimal" && "$IMAGE_SET" != "all" ]]; then
    echo "❌ Invalid parameter: $IMAGE_SET"
    echo ""
    echo "Usage: $0 [minimal|all]"
    echo ""
    echo "  minimal - Core infrastructure + RAG server (recommended for testing)"
    echo "  all     - Complete deployment with all optional components"
    exit 1
fi

echo "Image set: $IMAGE_SET"
echo "Output directory: ${RAG_IMAGES_DIR:-<will use default>}"
echo ""

# Track overall progress
TOTAL_SUCCESS=0
TOTAL_FAILED=0
START_TIME=$(date +%s)

# ==============================================================================
# Phase 1: Build Custom Images (with startscripts)
# ==============================================================================
echo "════════════════════════════════════════════════════════════════"
echo "Phase 1: Building Infrastructure Images"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "These images require custom Singularity startscripts to run as"
echo "background services via 'singularity instance start'."
echo ""

if "$SCRIPT_DIR/build-images.sh"; then
    BUILD_SUCCESS=$?
    TOTAL_SUCCESS=$((TOTAL_SUCCESS + 3))  # etcd, minio, milvus
else
    TOTAL_FAILED=$((TOTAL_FAILED + 3))
    echo ""
    echo "❌ Build phase failed. Aborting."
    exit 1
fi

echo ""

# ==============================================================================
# Phase 2: Pull Pre-built Images
# ==============================================================================
echo "════════════════════════════════════════════════════════════════"
echo "Phase 2: Pulling Pre-built Images"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "These images work directly from NGC/Docker registries without"
echo "customization."
echo ""

if "$SCRIPT_DIR/pull-images.sh" "$IMAGE_SET"; then
    # pull-images.sh will report its own success count
    PULL_SUCCESS=$?
else
    echo ""
    echo "⚠️  Some pulls failed, but continuing..."
fi

echo ""

# ==============================================================================
# Summary
# ==============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Duration: ${DURATION}s"
echo ""
echo "Images are ready at: ${RAG_IMAGES_DIR:-<default location>}"
echo ""
echo "Next steps:"
echo "  1. Verify images: singularity instance list"
echo "  2. Run tests: cd ../test && ./01-start-infrastructure.sh"
echo ""
