#!/bin/bash
# Rebuild only VLM image after fixing startscript

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/config.sh"

DEF_FILE="$SCRIPT_DIR/../definitions/vlm.def"
OUTPUT_FILE="$RAG_IMAGES_DIR/vlm.sif"

echo "=== Rebuilding VLM Image ==="
echo ""
echo "Definition: $DEF_FILE"
echo "Output:     $OUTPUT_FILE"
echo ""

# Backup old image if exists
if [ -f "$OUTPUT_FILE" ]; then
    BACKUP="$OUTPUT_FILE.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up old image to: $BACKUP"
    mv "$OUTPUT_FILE" "$BACKUP"
fi

echo "Building VLM image (this may take a few minutes)..."
singularity build "$OUTPUT_FILE" "$DEF_FILE"

if [ -f "$OUTPUT_FILE" ]; then
    echo ""
    echo "✅ VLM image rebuilt successfully"
    ls -lh "$OUTPUT_FILE"
    echo ""
    echo "Use nim-vlm.sh to start it, then: curl http://localhost:\$VLM_PORT/v1/health/ready"
else
    echo ""
    echo "❌ Build failed"
    exit 1
fi
