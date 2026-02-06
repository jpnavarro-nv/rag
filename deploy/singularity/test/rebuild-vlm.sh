#!/bin/bash
# Rebuild only VLM image after fixing startscript

set -e

source "$(dirname "$0")/00-config.sh"

DEF_FILE="../definitions/vlm.def"
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
    echo "Test with: ./test-vlm-only.sh"
else
    echo ""
    echo "❌ Build failed"
    exit 1
fi
