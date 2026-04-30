#!/bin/bash
# Pull llm-tools.sif (HuggingFace transformers-torch-light from Docker Hub).
#
# Includes: python3, huggingface-cli, requests (pre-installed in base image).
# No custom build needed — direct pull from Docker Hub.
#
# Usage:
#   ./build-tools-image.sh             # pull (skip if exists)
#   ./build-tools-image.sh --force     # re-pull even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -z "$LLM_BASE_DIR" ] && source "$SCRIPT_DIR/cluster-config.sh"

source "$SCRIPT_DIR/llm-config.sh"

SIF_PATH="$LLM_IMAGES_DIR/llm-tools.sif"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

if [ -f "$SIF_PATH" ] && [ "$FORCE" = false ]; then
    echo "llm-tools.sif already exists: $SIF_PATH"
    echo "Use --force to re-pull."
    exit 0
fi

mkdir -p "$LLM_IMAGES_DIR"

echo "Pulling llm-tools.sif (huggingface/transformers-torch-light)..."
echo "  Output: $SIF_PATH"
echo ""

singularity pull --force "$SIF_PATH" docker://huggingface/transformers-torch-light:latest

echo ""
echo "Done: $SIF_PATH ($(du -sh "$SIF_PATH" | cut -f1))"
