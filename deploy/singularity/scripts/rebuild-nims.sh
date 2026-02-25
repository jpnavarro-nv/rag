#!/bin/bash
# Rebuild NIM Singularity images from .def files
#
# Usage:
#   bash rebuild-nims.sh              # rebuild all NIMs
#   bash rebuild-nims.sh retrieval    # rebuild embedding + ranking + llm
#   bash rebuild-nims.sh ingest       # rebuild page-elements + graphic + table + paddle
#   bash rebuild-nims.sh vlm          # rebuild vlm only
#   bash rebuild-nims.sh llm          # rebuild nim-llm only
#
# Requires NGC_API_KEY for pulling from nvcr.io.
# Each image is 10-20GB; expect 10-30 min per image depending on network.

set -e

source "$(dirname "$0")/config.sh"

DEF_DIR="$(dirname "$0")/../definitions"

# ==============================================================================
# NGC Authentication for Singularity Docker pulls
# ==============================================================================
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

export SINGULARITY_DOCKER_USERNAME='$oauthtoken'
export SINGULARITY_DOCKER_PASSWORD="$NGC_API_KEY"
export APPTAINER_DOCKER_USERNAME='$oauthtoken'
export APPTAINER_DOCKER_PASSWORD="$NGC_API_KEY"

echo "✅ NGC auth configured for nvcr.io"
echo ""

# ==============================================================================
# Helper
# ==============================================================================
rebuild_image() {
    local name=$1
    local def_file="$DEF_DIR/${name}.def"
    local output="$RAG_IMAGES_DIR/${name}.sif"

    echo "--- Rebuilding $name ---"
    echo "    Def:    $def_file"
    echo "    Output: $output"

    if [ ! -f "$def_file" ]; then
        echo "    ❌ Definition file not found: $def_file"
        return 1
    fi

    # Backup existing image
    if [ -f "$output" ]; then
        local backup="${output}.backup-$(date +%Y%m%d-%H%M%S)"
        echo "    Backing up to: $backup"
        mv "$output" "$backup"
    fi

    echo "    Building... (this may take several minutes)"
    singularity build "$output" "$def_file"

    if [ -f "$output" ]; then
        echo "    ✅ Done: $(ls -lh "$output" | awk '{print $5}')"
    else
        echo "    ❌ Build failed"
        return 1
    fi
    echo ""
}

# ==============================================================================
# NIM groups
# ==============================================================================
build_retrieval() {
    echo "=== Rebuilding Retrieval NIMs ==="
    echo ""
    rebuild_image "nemoretriever-embedding"
    rebuild_image "nemoretriever-ranking"
    rebuild_image "nim-llm"
}

build_ingest() {
    echo "=== Rebuilding Ingest NIMs ==="
    echo ""
    rebuild_image "page-elements"
    rebuild_image "graphic-elements"
    rebuild_image "table-structure"
    rebuild_image "paddle"
}

build_vlm() {
    echo "=== Rebuilding VLM NIM ==="
    echo ""
    rebuild_image "vlm"
}

# ==============================================================================
# Main
# ==============================================================================
GROUP="${1:-all}"

case "$GROUP" in
    retrieval) build_retrieval ;;
    ingest)    build_ingest ;;
    vlm)       build_vlm ;;
    llm)       rebuild_image "nim-llm" ;;
    all)
        build_retrieval
        build_ingest
        build_vlm
        ;;
    *)
        echo "Unknown group: $GROUP"
        echo "Valid options: all, retrieval, ingest, vlm, llm"
        exit 1
        ;;
esac

echo "=== Rebuild complete ==="
echo "Images in: $RAG_IMAGES_DIR"
ls -lh "$RAG_IMAGES_DIR"/*.sif 2>/dev/null || echo "(no .sif files found)"
