#!/bin/bash
# Build nim-tools.sif from nim-tools.def.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./build-tools-image.sh             # build (skip if exists)
#   ./build-tools-image.sh --force     # rebuild even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

SIF_PATH="$NIM_IMAGES_DIR/nim-tools.sif"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

if [ -f "$SIF_PATH" ] && [ "$FORCE" = false ]; then
    echo "nim-tools.sif already exists: $SIF_PATH"
    echo "Use --force to rebuild."
    exit 0
fi

mkdir -p "$NIM_IMAGES_DIR"

echo "Building nim-tools.sif..."
echo "  Definition:    $SCRIPT_DIR/nim-tools.def"
echo "  Requirements:  $SCRIPT_DIR/requirements.txt"
echo "  Output:        $SIF_PATH"
echo ""

cd "$SCRIPT_DIR"
singularity build --fakeroot "$SIF_PATH" nim-tools.def
