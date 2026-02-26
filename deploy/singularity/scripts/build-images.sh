#!/bin/bash
# Build and pull all Singularity images for NVIDIA RAG Blueprint deployment.
#
# Images that require custom startscripts (instance start support) are built
# locally from .def files. Images distributed ready-to-use from NGC are
# pulled automatically when not already present.
#
# Usage:
#   ./build-images.sh            # build/pull everything
#   RAG_BASE_DIR=/path ./build-images.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# build-images.sh is a one-time setup script independent of the exec-session
# lifecycle managed by config.sh / 01-start-infrastructure.sh.
# It only needs the permanent container paths defined in dirs.sh.
export RAG_BASE_DIR="${RAG_BASE_DIR:-$HOME/rag-test}"
source "$SCRIPT_DIR/dirs.sh"

OUTPUT_DIR="$RAG_IMAGES_DIR"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$SINGULARITY_CACHEDIR"

echo "=== NVIDIA RAG Blueprint — Image Setup ==="
echo ""
echo "RAG_BASE_DIR:      $RAG_BASE_DIR"
echo "Output directory:  $OUTPUT_DIR"
echo "Singularity cache: $SINGULARITY_CACHEDIR"
echo ""
echo "ℹ️  To use a different deployment directory:"
echo "   RAG_BASE_DIR=/your/path ./build-images.sh"
echo ""

# ==============================================================================
# NGC authentication (env-var approach — NFS-safe, no credential files written)
# ==============================================================================

if [ -n "$NGC_API_KEY" ]; then
    export SINGULARITY_DOCKER_USERNAME='$oauthtoken'
    export SINGULARITY_DOCKER_PASSWORD="$NGC_API_KEY"
    echo "✅ NGC auth configured for nvcr.io"
    echo ""
else
    echo "⚠️  NGC_API_KEY not set — pulls from nvcr.io will fail."
    echo "   Export it before running: export NGC_API_KEY='your-key-here'"
    echo ""
fi

# ==============================================================================
# Helpers
# ==============================================================================

SUCCESS=0
FAILED=0


# Pull a .sif from a Docker/OCI registry.
# Skips silently when the image already exists.
pull_image() {
    local docker_uri=$1
    local sif_name=$2
    local description=$3
    local use_ngc_auth=${4:-true}

    echo "[$sif_name] $description"

    if [ -f "$OUTPUT_DIR/$sif_name" ]; then
        echo "    ✅ Already exists — skipped"
        SUCCESS=$((SUCCESS + 1))
        return 0
    fi

    echo "    Pulling from $docker_uri..."

    if [ "$use_ngc_auth" = "false" ]; then
        # Run in a subshell so credential vars are unset only for this pull
        if (
            unset SINGULARITY_DOCKER_USERNAME SINGULARITY_DOCKER_PASSWORD
            singularity pull "$OUTPUT_DIR/$sif_name" "docker://$docker_uri"
        ); then
            echo "    ✅ Pulled successfully"
            ls -lh "$OUTPUT_DIR/$sif_name" 2>/dev/null | awk '{print "       Size:", $5}' || true
            SUCCESS=$((SUCCESS + 1))
        else
            echo "    ❌ Pull failed"
            FAILED=$((FAILED + 1))
        fi
    else
        if singularity pull "$OUTPUT_DIR/$sif_name" "docker://$docker_uri"; then
            echo "    ✅ Pulled successfully"
            ls -lh "$OUTPUT_DIR/$sif_name" 2>/dev/null | awk '{print "       Size:", $5}' || true
            SUCCESS=$((SUCCESS + 1))
        else
            echo "    ❌ Pull failed"
            FAILED=$((FAILED + 1))
        fi
    fi
    echo ""
}

# ==============================================================================
# Blueprint services (pulled from NGC — no local .def)
# ==============================================================================

echo "=== Blueprint Services ==="
echo ""

pull_image "nvcr.io/nvidia/blueprint/rag-server:2.3.0" \
    "rag-server.sif" "RAG Server v2.3.0"

pull_image "nvcr.io/nvidia/blueprint/ingestor-server:2.3.0" \
    "ingestor-server.sif" "Ingestor Server v2.3.0"

# ==============================================================================
# Infrastructure (pulled from public registries — no NGC auth required)
# ==============================================================================

echo "=== Infrastructure Images ==="
echo ""

pull_image "quay.io/coreos/etcd:v3.6.5"                         "etcd.sif"   "etcd v3.6.5 - Key-value store"           false
pull_image "minio/minio:RELEASE.2025-09-07T16-13-09Z"           "minio.sif"  "MinIO RELEASE.2025-09-07 - Object storage" false
pull_image "milvusdb/milvus:v2.6.2-gpu"                         "milvus.sif" "Milvus v2.6.2-gpu - Vector database"     false
pull_image "redis/redis-stack:7.2.0-v18"                         "redis.sif"  "Redis Stack 7.2.0-v18 (matches compose)" false

# ==============================================================================
# NIM Models — Language (NGC auth required)
# ==============================================================================

echo "=== NIM Models — Language ==="
echo ""

pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.1"        "nemoretriever-embedding.sif" "NIM Embedding v1.10.1"
pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0"        "nemoretriever-ranking.sif"   "NIM Ranking v1.8.0"
pull_image "nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0" "nim-llm.sif"                 "NIM LLM v1.14.0 (49B model)"
pull_image "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-vl-8b-v1:1.3.1"   "vlm.sif"                     "NIM VLM v1.3.1 (8B model)"

# ==============================================================================
# NIM Models — Document Processing (NGC auth required)
# ==============================================================================

echo "=== NIM Models — Document Processing ==="
echo ""

pull_image "nvcr.io/nim/nvidia/nemoretriever-page-elements-v2:1.5.0"     "page-elements.sif"    "NIM Page Elements v1.5.0"
pull_image "nvcr.io/nim/nvidia/nemoretriever-graphic-elements-v1:1.5.0"  "graphic-elements.sif" "NIM Graphic Elements v1.5.0"
pull_image "nvcr.io/nim/nvidia/nemoretriever-table-structure-v1:1.5.0"   "table-structure.sif"  "NIM Table Structure v1.5.0"
pull_image "nvcr.io/nim/baidu/paddleocr:1.5.0"                           "paddle.sif"           "NIM PaddleOCR v1.5.0"

# ==============================================================================
# NV-Ingest + Frontend (NGC auth required)
# ==============================================================================

echo "=== NV-Ingest + Frontend ==="
echo ""

pull_image "nvcr.io/nvidia/nemo-microservices/nv-ingest:25.9.0" "nv-ingest.sif"    "NV-Ingest v25.9.0"
pull_image "nvcr.io/nvidia/blueprint/rag-frontend:2.3.0"        "rag-frontend.sif" "RAG Frontend UI v2.3.0"

# ==============================================================================
# Summary
# ==============================================================================

echo "=== Summary ==="
echo "✅ Success: $SUCCESS"
echo "❌ Failed:  $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "All images ready at: $OUTPUT_DIR"
    echo ""
    echo "Next step: ./01-start-infrastructure.sh"
else
    echo "⚠️  Some images failed. Check errors above."
    exit 1
fi
