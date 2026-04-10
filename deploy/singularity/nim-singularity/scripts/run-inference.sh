#!/bin/bash
# Convenience wrapper to run run_inference.py via nim-tools.sif.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#
#   ./scripts/run-inference.sh --url http://node:8999 "Your question"
#   ./scripts/run-inference.sh --list
#   ./scripts/run-inference.sh --help
#
# All arguments are forwarded to run_inference.py.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    exit 1
fi

export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

TOOLS_SIF="$NIM_IMAGES_DIR/nim-tools.sif"
if [ ! -f "$TOOLS_SIF" ]; then
    echo "ERROR: nim-tools.sif not found: $TOOLS_SIF"
    echo "Run './build-tools-image.sh' first."
    exit 1
fi

# Install requests at runtime via --writable-tmpfs, then run inference script.
# printf %q safely escapes each argument for embedding in bash -c.
ESCAPED_ARGS=$(printf '%q ' "$@")

singularity exec --writable-tmpfs \
    --bind "$SCRIPT_DIR:$SCRIPT_DIR" \
    --env NIM_SCRIPT_DIR="$SCRIPT_DIR" \
    "$TOOLS_SIF" \
    bash -c "pip install --quiet --no-warn-script-location requests && python3 \"\$NIM_SCRIPT_DIR/scripts/run_inference.py\" $ESCAPED_ARGS"
