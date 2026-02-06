#!/bin/bash
# Pull pre-built container images for RAG Singularity deployment
# These images work directly without requiring custom startscripts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${RAG_IMAGES_DIR:-/tmp/rag-images}"
IMAGE_SET="${1:-minimal}"

# Validate image set
if [[ "$IMAGE_SET" != "minimal" && "$IMAGE_SET" != "all" ]]; then
    echo "❌ Invalid parameter: $IMAGE_SET"
    echo "Usage: $0 [minimal|all]"
    exit 1
fi

echo "Pulling $IMAGE_SET image set"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Configure NGC authentication
if [ -z "$NGC_API_KEY" ]; then
    echo "⚠️  Warning: NGC_API_KEY not set"
    echo "   Export it before running: export NGC_API_KEY='your-key-here'"
    echo "   Continuing without authentication..."
    echo ""
else
    echo "✅ NGC_API_KEY found, logging into nvcr.io..."
    echo "$NGC_API_KEY" | singularity registry login --username '$oauthtoken' --password-stdin docker://nvcr.io > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Logged into NGC registry"
    else
        echo "❌ Login failed, pulls may fail"
    fi
    echo ""
fi

# Function to pull an image
pull_image() {
    local docker_uri=$1
    local sif_name=$2
    local description=$3
    local use_ngc_auth=${4:-true}

    echo "[$sif_name] $description"

    # Check if image already exists
    if [ -f "$OUTPUT_DIR/$sif_name" ]; then
        echo "    ✅ Already exists (skipped)"
        SUCCESS=$((SUCCESS + 1))
        return 0
    fi

    # Temporarily unset NGC credentials for public images
    if [ "$use_ngc_auth" = "false" ]; then
        local SAVED_USERNAME=$APPTAINER_DOCKER_USERNAME
        local SAVED_PASSWORD=$APPTAINER_DOCKER_PASSWORD
        unset APPTAINER_DOCKER_USERNAME
        unset APPTAINER_DOCKER_PASSWORD
    fi

    echo "    Pulling from $docker_uri..."
    if singularity pull "$OUTPUT_DIR/$sif_name" "docker://$docker_uri" > /dev/null 2>&1; then
        echo "    ✅ Pulled successfully"
        ls -lh "$OUTPUT_DIR/$sif_name" | awk '{print "       Size:", $5}'
        SUCCESS=$((SUCCESS + 1))
    else
        echo "    ❌ Pull failed"
        echo "       Run manually to see error: singularity pull $OUTPUT_DIR/$sif_name docker://$docker_uri"
        FAILED=$((FAILED + 1))
    fi

    # Restore NGC credentials if they were unset
    if [ "$use_ngc_auth" = "false" ]; then
        export APPTAINER_DOCKER_USERNAME=$SAVED_USERNAME
        export APPTAINER_DOCKER_PASSWORD=$SAVED_PASSWORD
    fi

    echo ""
}

# Track results
SUCCESS=0
FAILED=0

# ==============================================================================
# Core RAG Services (always pulled for minimal setup)
# ==============================================================================
echo "=== Core RAG Services ==="
echo ""

pull_image "nvcr.io/nvidia/blueprint/rag-server:2.3.0" \
    "rag-server.sif" \
    "RAG Server v2.3.0"

pull_image "nvcr.io/nvidia/blueprint/ingestor-server:2.3.0" \
    "ingestor-server.sif" \
    "Ingestor Server v2.3.0"

# ==============================================================================
# Additional Services for Full Pipeline (only for 'all')
# ==============================================================================
if [ "$IMAGE_SET" = "all" ]; then
    echo ""
    echo "=== Message Queue ==="
    echo ""

    pull_image "redis/redis-stack:7.2.0-v18" \
        "redis.sif" \
        "Redis Stack v7.2.0" \
        "false"

    echo ""
    echo "=== Optional/Extras ==="
    echo ""

    pull_image "nvcr.io/nvidia/blueprint/rag-frontend:2.3.0" \
        "frontend.sif" \
        "Frontend UI v2.3.0 (optional)"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "NOTE: NIMs and NV-Ingest are now built locally from .def files"
echo "      Run build-images.sh to build them (required for full stack)"
echo "════════════════════════════════════════════════════════════════"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=== Pull Summary ==="
echo "✅ Success: $SUCCESS"
echo "❌ Failed:  $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "🎉 All images pulled successfully!"
else
    echo "⚠️  Some pulls failed. Check errors above."
fi

exit 0
