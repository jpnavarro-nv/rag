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

# Check NGC authentication
if [ -z "$APPTAINER_DOCKER_USERNAME" ] || [ -z "$APPTAINER_DOCKER_PASSWORD" ]; then
    echo "⚠️  Warning: NGC credentials not found"
    echo "   Set APPTAINER_DOCKER_USERNAME and APPTAINER_DOCKER_PASSWORD"
    echo "   or run: singularity remote login"
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
# Core RAG Services (always pulled)
# ==============================================================================
echo "=== Core RAG Services ==="
echo ""

pull_image "nvcr.io/ohlfw0olaadg/ea-participants/nemo-retriever-embedding-microservice:24.08" \
    "nemo-retriever-embedding-microservice.sif" \
    "NeMo Retriever Embedding NIM"

pull_image "nvcr.io/ohlfw0olaadg/ea-participants/nemo-retriever-ranking-microservice:24.08" \
    "nemo-retriever-ranking-microservice.sif" \
    "NeMo Retriever Ranking NIM"

pull_image "nvcr.io/ohlfw0olaadg/ea-participants/nemo-retriever-reranking-microservice:24.08" \
    "nemo-retriever-reranking-microservice.sif" \
    "NeMo Retriever Reranking NIM"

pull_image "nvcr.io/nvidia/rag-playground-rag-server:24.12" \
    "rag-server.sif" \
    "RAG Server"

pull_image "nvcr.io/nvidia/rag-playground-ingest-server:24.12" \
    "ingestor-server.sif" \
    "Ingestor Server"

pull_image "nvcr.io/nvidia/rag-playground-ui:24.12" \
    "frontend.sif" \
    "Frontend UI"

# ==============================================================================
# Optional Components (only for 'all')
# ==============================================================================
if [ "$IMAGE_SET" = "all" ]; then
    echo ""
    echo "=== Optional NIMs ==="
    echo ""

    pull_image "nvcr.io/nim/nvidia/llama-3_1-8b-instruct:1.2.2" \
        "nim-llama-3_1-8b-instruct.sif" \
        "NIM LLM - Llama 3.1 8B"

    pull_image "nvcr.io/nim/nvidia/llama-3_1-70b-instruct:1.2.2" \
        "nim-llama-3_1-70b-instruct.sif" \
        "NIM LLM - Llama 3.1 70B"

    pull_image "nvcr.io/nim/nvidia/mistral-nemo-12b-instruct:1.1.0" \
        "nim-mistral-nemo-12b-instruct.sif" \
        "NIM LLM - Mistral NeMo 12B"

    pull_image "nvcr.io/nim/nvidia/nv-embedqa-e5-v5:1.0.1" \
        "nim-nv-embedqa-e5-v5.sif" \
        "NIM Embedding - E5 v5"

    pull_image "nvcr.io/nim/nvidia/nv-rerankqa-mistral-4b-v3:1.0.1" \
        "nim-nv-rerankqa-mistral-4b-v3.sif" \
        "NIM Reranking - Mistral 4B"

    pull_image "nvcr.io/nim/nvidia/arctic-embed-l:1.0.0" \
        "nim-arctic-embed-l.sif" \
        "NIM Embedding - Arctic"

    echo ""
    echo "=== Optional Tools ==="
    echo ""

    pull_image "nvcr.io/nvidia/rag-playground-evaluation:24.12" \
        "evaluation.sif" \
        "Evaluation Tools"

    pull_image "nvcr.io/nvidia/rag-playground-notebook:24.12" \
        "notebook.sif" \
        "Jupyter Notebook"
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
