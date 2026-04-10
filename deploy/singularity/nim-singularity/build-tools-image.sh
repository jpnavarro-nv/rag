#!/bin/bash
# Pull the nim-tools.sif utility container from GHCR.
#
# Python packages (huggingface-hub, requests, openai) are pre-installed
# in the image via GitHub Actions CI. No pip install at runtime.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./build-tools-image.sh             # pull (skip if exists)
#   ./build-tools-image.sh --force     # re-pull even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo ""
    echo "Set it to the shared directory for NIM data:"
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

# Source paths only (NGC_API_KEY not needed for tools pull)
export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

SIF_PATH="$NIM_IMAGES_DIR/nim-tools.sif"

# Parse --force flag
FORCE=false
[ "$1" = "--force" ] && FORCE=true

if [ -f "$SIF_PATH" ] && [ "$FORCE" = false ]; then
    echo "nim-tools.sif already exists: $SIF_PATH"
    echo "Use --force to re-pull."
    exit 0
fi

mkdir -p "$NIM_IMAGES_DIR"

echo "Pulling nim-tools.sif from GHCR..."
echo "  Output: $SIF_PATH"
echo ""

singularity pull --force "$SIF_PATH" docker://ghcr.io/jpnavarro-nv/nim-tools:latest

echo ""
echo "Done: $SIF_PATH ($(du -sh "$SIF_PATH" | cut -f1))"
