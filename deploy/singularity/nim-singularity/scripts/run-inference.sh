#!/bin/bash
# Run inference via nim-tools.sif. All arguments forwarded to run_inference.py.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./scripts/run-inference.sh --url http://node:8999 "Your question"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -z "$NIM_BASE_DIR" ] && { echo "ERROR: NIM_BASE_DIR is not set."; exit 1; }

export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

TOOLS_SIF="$NIM_IMAGES_DIR/nim-tools.sif"
[ ! -f "$TOOLS_SIF" ] && { echo "ERROR: nim-tools.sif not found. Run ./build-tools-image.sh first."; exit 1; }

singularity exec \
    --bind "$SCRIPT_DIR:$SCRIPT_DIR" \
    "$TOOLS_SIF" \
    python3 "$SCRIPT_DIR/scripts/run_inference.py" "$@"
