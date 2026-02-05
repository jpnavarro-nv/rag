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
# Full Ingestion Pipeline (only for 'all')
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
    echo "=== NIMs - Language Models ==="
    echo ""

    pull_image "nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0" \
        "nim-llm.sif" \
        "NIM LLM - Llama 3.3 Nemotron 49B"

    pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.1" \
        "nemoretriever-embedding.sif" \
        "NIM Embedding - Llama 3.2 EmbedQA 1B"

    pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0" \
        "nemoretriever-ranking.sif" \
        "NIM Reranking - Llama 3.2 RerankQA 1B"

    pull_image "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-vl-8b-v1:1.3.1" \
        "vlm.sif" \
        "NIM VLM - Llama 3.1 Nemotron Nano VL 8B"

    echo ""
    echo "=== NIMs - Document Processing ==="
    echo ""

    pull_image "nvcr.io/nim/nvidia/nemoretriever-page-elements-v2:1.5.0" \
        "page-elements.sif" \
        "NIM Page Elements (YOLOX) v2"

    pull_image "nvcr.io/nim/nvidia/nemoretriever-graphic-elements-v1:1.5.0" \
        "graphic-elements.sif" \
        "NIM Graphic Elements (YOLOX) v1"

    pull_image "nvcr.io/nim/nvidia/nemoretriever-table-structure-v1:1.5.0" \
        "table-structure.sif" \
        "NIM Table Structure (YOLOX) v1"

    pull_image "nvcr.io/nim/baidu/paddleocr:1.5.0" \
        "paddle.sif" \
        "NIM PaddleOCR v1.5.0"

    echo ""
    echo "=== NV-Ingest Runtime ==="
    echo ""

    pull_image "nvcr.io/nvidia/nemo-microservices/nv-ingest:25.9.0" \
        "nv-ingest.sif" \
        "NV-Ingest Microservice v25.9.0"

    echo ""
    echo "=== Optional/Extras ==="
    echo ""

    pull_image "nvcr.io/nvidia/blueprint/rag-frontend:2.3.0" \
        "frontend.sif" \
        "Frontend UI v2.3.0 (optional)"
fi

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
