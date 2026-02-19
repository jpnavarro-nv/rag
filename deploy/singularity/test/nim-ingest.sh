#!/bin/bash
# Start Ingest NIMs: Page Elements + Graphic Elements + Table Structure + PaddleOCR
# Required for document ingestion (PDF parsing, layout detection, OCR).
# Equivalent to Docker Compose profile "ingest".
#
# Run standalone:  bash nim-ingest.sh
# Or via full stack: bash 04-start-nim-models.sh
set -e

source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

echo "=== Starting Ingest NIMs ==="
echo "   Page Elements:    localhost:$PAGE_ELEMENTS_PORT  (GPU $PAGE_ELEMENTS_GPU_ID)"
echo "   Graphic Elements: localhost:$GRAPHIC_ELEMENTS_PORT  (GPU $GRAPHIC_ELEMENTS_GPU_ID)"
echo "   Table Structure:  localhost:$TABLE_STRUCTURE_PORT  (GPU $TABLE_STRUCTURE_GPU_ID)"
echo "   PaddleOCR:        localhost:$PADDLE_OCR_PORT  (GPU $PADDLE_OCR_GPU_ID)"
echo ""

# Writable cache dirs for model weights
PAGE_ELEMENTS_CACHE_DIR="$RAG_BASE_DIR/models/page-elements-cache"
GRAPHIC_ELEMENTS_CACHE_DIR="$RAG_BASE_DIR/models/graphic-elements-cache"
TABLE_STRUCTURE_CACHE_DIR="$RAG_BASE_DIR/models/table-structure-cache"
PADDLE_OCR_CACHE_DIR="$RAG_BASE_DIR/models/paddle-ocr-cache"
mkdir -p "$PAGE_ELEMENTS_CACHE_DIR" "$GRAPHIC_ELEMENTS_CACHE_DIR" \
         "$TABLE_STRUCTURE_CACHE_DIR" "$PADDLE_OCR_CACHE_DIR"

# Triton NIMs: singularity run (Docker entrypoint), port via NIM_HTTP_API_PORT
start_nim_service "page-elements" "$PAGE_ELEMENTS_PORT" "$PAGE_ELEMENTS_GPU_ID" \
    "page-elements.sif" \
    "--bind $PAGE_ELEMENTS_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$PAGE_ELEMENTS_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

start_nim_service "graphic-elements" "$GRAPHIC_ELEMENTS_PORT" "$GRAPHIC_ELEMENTS_GPU_ID" \
    "graphic-elements.sif" \
    "--bind $GRAPHIC_ELEMENTS_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$GRAPHIC_ELEMENTS_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

start_nim_service "table-structure" "$TABLE_STRUCTURE_PORT" "$TABLE_STRUCTURE_GPU_ID" \
    "table-structure.sif" \
    "--bind $TABLE_STRUCTURE_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$TABLE_STRUCTURE_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

start_nim_service "paddle-ocr" "$PADDLE_OCR_PORT" "$PADDLE_OCR_GPU_ID" \
    "paddle.sif" \
    "--bind $PADDLE_OCR_CACHE_DIR:/opt/nim/.cache --env NIM_HTTP_API_PORT=$PADDLE_OCR_PORT --env NIM_CACHE_PATH=/opt/nim/.cache"

echo ""
echo "✅ Ingest NIMs launched"
echo "   Monitor: tail -f $RAG_LOGS_DIR/page-elements.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/graphic-elements.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/table-structure.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/paddle-ocr.log"
echo ""
echo "⚠️  Models load in ~2 min. All share GPU $PAGE_ELEMENTS_GPU_ID."
