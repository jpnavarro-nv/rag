#!/bin/bash
# Pull all Singularity images for NVIDIA RAG Blueprint deployment.
# All images are pulled from their registries (NGC for NIMs/blueprints,
# public registries for infrastructure). Already-existing SIFs are skipped.
#
# Usage:
#   ./build-images.sh            # pull everything
#   RAG_BASE_DIR=/path ./build-images.sh

set -e

# ==============================================================================
# Version pinning — update here to upgrade images
# ==============================================================================

# Blueprint services (rag-server, ingestor-server, rag-frontend share one tag)
TAG="2.3.0"

# Infrastructure
ETCD_VERSION="v3.6.5"
MINIO_VERSION="RELEASE.2025-09-07T16-13-09Z"
MILVUS_VERSION="v2.6.2-gpu"
REDIS_VERSION="7.2.0-v18"

# NIM — Language models
NIM_LLM_VERSION="1.14.0"
NIM_EMBEDDING_VERSION="1.10.1"
NIM_RANKING_VERSION="1.8.0"
NIM_VLM_VERSION="1.3.1"

# NIM — Document processing
NIM_PAGE_ELEMENTS_VERSION="1.5.0"
NIM_GRAPHIC_ELEMENTS_VERSION="1.5.0"
NIM_TABLE_STRUCTURE_VERSION="1.5.0"
NIM_PADDLEOCR_VERSION="1.5.0"

# NV-Ingest pipeline
NV_INGEST_VERSION="25.9.0"

# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# build-images.sh is a one-time setup script independent of the exec-session
# lifecycle managed by config.sh / 01-start-infrastructure.sh.
# It only needs the permanent container paths defined in dirs.sh.
export RAG_BASE_DIR="${RAG_BASE_DIR:-$HOME/rag-test}"
source "$SCRIPT_DIR/run/dirs.sh"

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
# Blueprint services (pulled from NGC)
# ==============================================================================

echo "=== Blueprint Services ==="
echo ""

pull_image "nvcr.io/nvidia/blueprint/rag-server:$TAG" \
    "rag-server.sif" "RAG Server v$TAG"

pull_image "nvcr.io/nvidia/blueprint/ingestor-server:$TAG" \
    "ingestor-server.sif" "Ingestor Server v$TAG"

# ==============================================================================
# Infrastructure (pulled from public registries — no NGC auth required)
# ==============================================================================

echo "=== Infrastructure Images ==="
echo ""

pull_image "quay.io/coreos/etcd:$ETCD_VERSION"                   "etcd.sif"   "etcd $ETCD_VERSION - Key-value store"           false
pull_image "minio/minio:$MINIO_VERSION"                          "minio.sif"  "MinIO $MINIO_VERSION - Object storage"          false
pull_image "milvusdb/milvus:$MILVUS_VERSION"                     "milvus.sif" "Milvus $MILVUS_VERSION - Vector database"        false
# redis-stack (not plain redis) — matches compose; nv-ingest expects it
pull_image "redis/redis-stack:$REDIS_VERSION"                    "redis.sif"  "Redis Stack $REDIS_VERSION"                     false

# ==============================================================================
# NIM Models — Language (NGC auth required)
# ==============================================================================

echo "=== NIM Models — Language ==="
echo ""

pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:$NIM_EMBEDDING_VERSION"        "nemoretriever-embedding.sif" "NIM Embedding v$NIM_EMBEDDING_VERSION"
pull_image "nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:$NIM_RANKING_VERSION"        "nemoretriever-ranking.sif"   "NIM Ranking v$NIM_RANKING_VERSION"
pull_image "nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:$NIM_LLM_VERSION"      "nim-llm.sif"                 "NIM LLM v$NIM_LLM_VERSION (49B model)"
pull_image "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-vl-8b-v1:$NIM_VLM_VERSION"       "vlm.sif"                     "NIM VLM v$NIM_VLM_VERSION (8B model)"

# ==============================================================================
# NIM Models — Document Processing (NGC auth required)
# ==============================================================================

echo "=== NIM Models — Document Processing ==="
echo ""

pull_image "nvcr.io/nim/nvidia/nemoretriever-page-elements-v2:$NIM_PAGE_ELEMENTS_VERSION"    "page-elements.sif"    "NIM Page Elements v$NIM_PAGE_ELEMENTS_VERSION"
pull_image "nvcr.io/nim/nvidia/nemoretriever-graphic-elements-v1:$NIM_GRAPHIC_ELEMENTS_VERSION" "graphic-elements.sif" "NIM Graphic Elements v$NIM_GRAPHIC_ELEMENTS_VERSION"
pull_image "nvcr.io/nim/nvidia/nemoretriever-table-structure-v1:$NIM_TABLE_STRUCTURE_VERSION"  "table-structure.sif"  "NIM Table Structure v$NIM_TABLE_STRUCTURE_VERSION"
pull_image "nvcr.io/nim/baidu/paddleocr:$NIM_PADDLEOCR_VERSION"                               "paddle.sif"           "NIM PaddleOCR v$NIM_PADDLEOCR_VERSION"

# ==============================================================================
# NV-Ingest + Frontend (NGC auth required)
# ==============================================================================

echo "=== NV-Ingest + Frontend ==="
echo ""

pull_image "nvcr.io/nvidia/nemo-microservices/nv-ingest:$NV_INGEST_VERSION" "nv-ingest.sif"    "NV-Ingest v$NV_INGEST_VERSION"
pull_image "nvcr.io/nvidia/blueprint/rag-frontend:$TAG"                   "rag-frontend.sif" "RAG Frontend UI v$TAG"

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
    echo "Next step: cd run && ./01-start-infrastructure.sh"
else
    echo "⚠️  Some images failed. Check errors above."
    exit 1
fi
