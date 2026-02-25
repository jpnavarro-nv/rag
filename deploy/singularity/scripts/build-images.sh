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
DEF_DIR="$SCRIPT_DIR/../definitions"

# build-images.sh is a one-time setup script independent of the exec-session
# lifecycle managed by config.sh / 01-start-infrastructure.sh.
# It only needs the permanent container paths defined in dirs.sh.
export RAG_BASE_DIR="${RAG_BASE_DIR:-$HOME/rag-test}"
source "$SCRIPT_DIR/dirs.sh"

OUTPUT_DIR="$RAG_IMAGES_DIR"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$APPTAINER_CACHEDIR"

echo "=== NVIDIA RAG Blueprint — Image Setup ==="
echo ""
echo "RAG_BASE_DIR:      $RAG_BASE_DIR"
echo "Definition files:  $DEF_DIR"
echo "Output directory:  $OUTPUT_DIR"
echo "Apptainer cache:   $APPTAINER_CACHEDIR"
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
    export APPTAINER_DOCKER_USERNAME='$oauthtoken'
    export APPTAINER_DOCKER_PASSWORD="$NGC_API_KEY"
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

# Build a .sif from a local .def file.
# Skips silently when the image already exists.
build_image() {
    local def_file=$1
    local sif_name=$2
    local description=$3

    echo "[$sif_name] $description"

    if [ -f "$OUTPUT_DIR/$sif_name" ]; then
        echo "    ✅ Already exists — skipped"
        SUCCESS=$((SUCCESS + 1))
        return 0
    fi

    echo "    Building from $def_file..."
    if singularity build --proot "$OUTPUT_DIR/$sif_name" "$DEF_DIR/$def_file"; then
        echo "    ✅ Built successfully"
        ls -lh "$OUTPUT_DIR/$sif_name" 2>/dev/null | awk '{print "       Size:", $5}' || true
        SUCCESS=$((SUCCESS + 1))
    else
        echo "    ❌ Build failed"
        FAILED=$((FAILED + 1))
    fi
    echo ""
}

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
            unset APPTAINER_DOCKER_USERNAME APPTAINER_DOCKER_PASSWORD
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
# Infrastructure (built locally — require custom startscripts)
# ==============================================================================

echo "=== Infrastructure Images ==="
echo ""

build_image "etcd.def"   "etcd.sif"   "etcd - Key-value store"
build_image "minio.def"  "minio.sif"  "MinIO - Object storage"
build_image "milvus.def" "milvus.sif" "Milvus v2.6.2-gpu - Vector database"

# ==============================================================================
# NIM Models — Language
# ==============================================================================

echo "=== NIM Models — Language ==="
echo ""

build_image "nemoretriever-embedding.def" "nemoretriever-embedding.sif" "NIM Embedding v1.10.1"
build_image "nemoretriever-ranking.def"   "nemoretriever-ranking.sif"   "NIM Ranking v1.8.0"
build_image "nim-llm.def"                 "nim-llm.sif"                 "NIM LLM v1.14.0 (49B model)"
build_image "vlm.def"                     "vlm.sif"                     "NIM VLM v1.3.1 (8B model)"

# ==============================================================================
# NIM Models — Document Processing
# ==============================================================================

echo "=== NIM Models — Document Processing ==="
echo ""

build_image "page-elements.def"    "page-elements.sif"    "NIM Page Elements v1.5.0"
build_image "graphic-elements.def" "graphic-elements.sif" "NIM Graphic Elements v1.5.0"
build_image "table-structure.def"  "table-structure.sif"  "NIM Table Structure v1.5.0"
build_image "paddle.def"           "paddle.sif"           "NIM PaddleOCR v1.5.0"

# ==============================================================================
# NV-Ingest + Frontend
# ==============================================================================

echo "=== NV-Ingest + Frontend ==="
echo ""

build_image "nv-ingest.def"    "nv-ingest.sif"    "NV-Ingest v25.9.0"
build_image "rag-frontend.def" "rag-frontend.sif" "RAG Frontend UI v2.3.0"

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
