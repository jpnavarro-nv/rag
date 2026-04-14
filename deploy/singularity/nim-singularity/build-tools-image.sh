#!/bin/bash
# Pull nim-tools.sif (HuggingFace transformers-torch-light from Docker Hub).
#
# Includes: python3, huggingface-cli, requests (pre-installed in base image).
# No custom build needed — direct pull from Docker Hub.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./build-tools-image.sh             # pull (skip if exists)
#   ./build-tools-image.sh --force     # re-pull even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

source "$SCRIPT_DIR/nim-config.sh"

SIF_PATH="$NIM_IMAGES_DIR/nim-tools.sif"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

if [ -f "$SIF_PATH" ] && [ "$FORCE" = false ]; then
    echo "nim-tools.sif already exists: $SIF_PATH"
    echo "Use --force to re-pull."
    exit 0
fi

mkdir -p "$NIM_IMAGES_DIR"

echo "Pulling nim-tools.sif (huggingface/transformers-torch-light)..."
echo "  Output: $SIF_PATH"
echo ""

singularity pull --force "$SIF_PATH" docker://huggingface/transformers-torch-light:latest

echo ""
echo "Done: $SIF_PATH ($(du -sh "$SIF_PATH" | cut -f1))"
