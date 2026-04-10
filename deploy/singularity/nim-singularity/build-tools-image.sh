#!/bin/bash
# Build the nim-tools.sif utility container.
#
# Requires apptainer/singularity with --fakeroot support.
# The resulting SIF provides: huggingface-cli, python3 with requests/openai.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./build-tools-image.sh             # build (skip if exists)
#   ./build-tools-image.sh --force     # rebuild even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo ""
    echo "Set it to the shared directory for NIM data:"
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

# Source paths only (NGC_API_KEY not needed for tools build)
export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

SIF_PATH="$NIM_IMAGES_DIR/nim-tools.sif"
DEF_PATH="$SCRIPT_DIR/nim-tools.def"

# Parse --force flag
FORCE=false
[ "$1" = "--force" ] && FORCE=true

if [ -f "$SIF_PATH" ] && [ "$FORCE" = false ]; then
    echo "nim-tools.sif already exists: $SIF_PATH"
    echo "Use --force to rebuild."
    exit 0
fi

mkdir -p "$NIM_IMAGES_DIR"

echo "Building nim-tools.sif..."
echo "  Definition: $DEF_PATH"
echo "  Output:     $SIF_PATH"
echo ""

apptainer build --fakeroot "$SIF_PATH" "$DEF_PATH"

echo ""
echo "Done: $SIF_PATH ($(du -sh "$SIF_PATH" | cut -f1))"
