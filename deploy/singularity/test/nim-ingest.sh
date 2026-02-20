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

# ==============================================================================
# Health-wait helper
# ==============================================================================
# Object Detection NIMs (page-elements, graphic-elements, table-structure,
# paddle-ocr) take ~25-40 s to become ready:
#   - ~15 s to start Triton + load TensorRT engine
#   - several more seconds for uvicorn workers to connect and serve /health/ready
#
# NIM_HTTP_API_WORKERS is NOT honoured by the Object Detection NIM SDK (it is
# specific to the NeMo Retriever SDK used by embedding/ranking).  Workers
# default to nproc (16), which is tolerable because these NIMs use TensorRT
# (not Python BLS) backend — only yolox_pre and yolox_post are Python and each
# has exactly 1 instance.
#
# start_nim_service only waits 3 s (process-alive check), so we add an
# explicit health-wait here, same pattern as 06-start-nv-ingest-ms.sh.
wait_for_ingest_nim() {
    local name=$1
    local port=$2
    local max_attempts=${3:-60}   # default 120 s (2 s sleep per attempt)
    local attempt=1

    echo "   ⏳ Waiting for $name to be ready (up to $((max_attempts * 2))s)..."
    while [ $attempt -le $max_attempts ]; do
        if curl -s --max-time 3 "http://localhost:${port}/v1/health/ready" > /dev/null 2>&1; then
            echo "   ✅ $name ready (${attempt} × 2s elapsed)"
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    echo "   ❌ $name not ready after $((max_attempts * 2))s"
    echo "      check: tail -80 $RAG_LOGS_DIR/${name}.log"
    return 1
}

echo "=== Starting Ingest NIMs ==="
echo "   Page Elements:    localhost:$PAGE_ELEMENTS_PORT  (GPU $PAGE_ELEMENTS_GPU_ID)"
echo "   Graphic Elements: localhost:$GRAPHIC_ELEMENTS_PORT  (GPU $GRAPHIC_ELEMENTS_GPU_ID)"
echo "   Table Structure:  localhost:$TABLE_STRUCTURE_PORT  (GPU $TABLE_STRUCTURE_GPU_ID)"
echo "   PaddleOCR:        localhost:$PADDLE_OCR_PORT  (GPU $PADDLE_OCR_GPU_ID)"
echo ""

# Persistent dirs for model weights, manifests and workspace
PAGE_ELEMENTS_CACHE_DIR="$RAG_BASE_DIR/models/page-elements-cache"
GRAPHIC_ELEMENTS_CACHE_DIR="$RAG_BASE_DIR/models/graphic-elements-cache"
TABLE_STRUCTURE_CACHE_DIR="$RAG_BASE_DIR/models/table-structure-cache"
PADDLE_OCR_CACHE_DIR="$RAG_BASE_DIR/models/paddle-ocr-cache"
PAGE_ELEMENTS_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/page-elements"
GRAPHIC_ELEMENTS_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/graphic-elements"
TABLE_STRUCTURE_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/table-structure"
PADDLE_OCR_WORK_DIR="$RAG_BASE_DIR/runtime/nim-work/paddle-ocr"
mkdir -p "$PAGE_ELEMENTS_CACHE_DIR"    "$PAGE_ELEMENTS_WORK_DIR/tmp"    "$PAGE_ELEMENTS_WORK_DIR/workspace"
mkdir -p "$GRAPHIC_ELEMENTS_CACHE_DIR" "$GRAPHIC_ELEMENTS_WORK_DIR/tmp" "$GRAPHIC_ELEMENTS_WORK_DIR/workspace"
mkdir -p "$TABLE_STRUCTURE_CACHE_DIR"  "$TABLE_STRUCTURE_WORK_DIR/tmp"  "$TABLE_STRUCTURE_WORK_DIR/workspace"
mkdir -p "$PADDLE_OCR_CACHE_DIR"       "$PADDLE_OCR_WORK_DIR/tmp"       "$PADDLE_OCR_WORK_DIR/workspace"

# ==============================================================================
# Triton port isolation — Singularity has no network namespace
# ==============================================================================
# In Docker each container has its own network namespace, so all 4 NIMs can
# use Triton's defaults (gRPC=8001, HTTP=8080, metrics=8002) without conflict.
# In Singularity every container shares the host network, so each NIM must
# listen on unique ports across all three Triton interfaces.
#
# Variables:
#   NIM_HTTP_TRITON_PORT    — Triton HTTP port  (maps to triton_start.sh -h flag)
#   NIM_TRITON_METRICS_PORT — Triton metrics    (maps to triton_start.sh -p flag)
#   NIM_TRITON_GRPC_PORT    — Triton gRPC port  (NeMo Retriever SDK; may or may
#                              not be recognised by the ingest NIM family)
#   NIM_TRITON_EXTRA_ARGS   — appended verbatim to triton_start.sh; used as
#                              fallback to set --grpc-port when NIM_TRITON_GRPC_PORT
#                              is not recognised by the NIM
#
# NIM_TRITON_EXTRA_ARGS quoting strategy:
#   The singularity_opts string in nim-lib.sh is expanded unquoted (word-split).
#   A --env KEY=VALUE with spaces in VALUE would be split into separate flags.
#   Solution: export NIM_TRITON_EXTRA_ARGS into the shell environment before each
#   start_nim_service call.  singularity run (without --cleanenv) inherits parent
#   env vars.  The & fork captures the correct value at fork time, so the
#   sequential export pattern is safe even though processes run concurrently.
#
# nv-ingest connects to Triton gRPC at PORT+1 for every ingest NIM
# (see 06-start-nv-ingest-ms.sh).  gRPC values must equal PORT+1:
#   page-elements    gRPC=8001  (8000+1)
#   graphic-elements gRPC=8004  (8003+1)
#   table-structure  gRPC=8007  (8006+1)
#   paddle-ocr       gRPC=8010  (8009+1)
#
# Full port map (no conflicts with embedding 9000-9002 or ranking 8060-8061,8011):
#   NIM               uvicorn  gRPC   Triton-HTTP  metrics
#   page-elements     8000     8001   8020         8021
#   graphic-elements  8003     8004   8030         8031
#   table-structure   8006     8007   8040         8041
#   paddle-ocr        8009     8010   8050         8051
#
# NIM_TRITON_EXTRA_ARGS cuda args:
#   The ingest NIMs set NIM_TRITON_EXTRA_ARGS internally to:
#   "--cuda-memory-pool-byte-size=0:402663424.0 --backend-config=tensorrt,version-compatible=true"
#   We preserve those args and append --grpc-port.  The 402663424 value (384 MiB,
#   formatted as a float by the NIM) is the NIM's own default and is safe to
#   hard-code here — it does not depend on GPU model or GPU memory size.
_INGEST_CUDA_ARGS="--cuda-memory-pool-byte-size=0:402663424.0 --backend-config=tensorrt,version-compatible=true"

# NIM_HTTP_API_WORKERS: controls uvicorn HTTP workers spawned at startup.
# In Singularity (SquashFS read-only filesystem), all workers import Python
# modules simultaneously, causing I/O contention that can exceed internal
# health-check timeouts.  Reducing to 2 avoids the thundering-herd on startup
# while still allowing some request concurrency.
# Ingest NIMs have only 1 Triton Python stub instance (yolox_pre/post) so
# the stub thundering-herd from embedding/ranking does not apply here; the
# fix matters only for the uvicorn worker count.
# Overridable via: export NIM_HTTP_API_WORKERS=N
_INGEST_WORKERS=${NIM_HTTP_API_WORKERS:-2}

# Triton NIMs: singularity run (Docker entrypoint), port via NIM_HTTP_API_PORT
#
# Belt-and-suspenders for gRPC isolation:
#   1. --env NIM_TRITON_GRPC_PORT=XXXX  (works if NIM honours this variable)
#   2. export NIM_TRITON_EXTRA_ARGS with --grpc-port=XXXX  (works via triton_start.sh)
# Both coexist safely: if NIM_TRITON_GRPC_PORT is recognised it takes effect
# before Triton processes NIM_TRITON_EXTRA_ARGS, so there is no double-binding.

export NIM_TRITON_EXTRA_ARGS="${_INGEST_CUDA_ARGS} --grpc-port=8001"
start_nim_service "page-elements" "$PAGE_ELEMENTS_PORT" "$PAGE_ELEMENTS_GPU_ID" \
    "page-elements.sif" \
    "$NVML_BIND --bind $PAGE_ELEMENTS_CACHE_DIR:/opt/nim/.cache --bind $PAGE_ELEMENTS_WORK_DIR/tmp:/opt/nim/tmp --bind $PAGE_ELEMENTS_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$PAGE_ELEMENTS_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_INGEST_WORKERS --env NIM_TRITON_GRPC_PORT=8001 --env NIM_HTTP_TRITON_PORT=8020 --env NIM_TRITON_METRICS_PORT=8021"
wait_for_ingest_nim "page-elements" "$PAGE_ELEMENTS_PORT" || exit 1

export NIM_TRITON_EXTRA_ARGS="${_INGEST_CUDA_ARGS} --grpc-port=8004"
start_nim_service "graphic-elements" "$GRAPHIC_ELEMENTS_PORT" "$GRAPHIC_ELEMENTS_GPU_ID" \
    "graphic-elements.sif" \
    "$NVML_BIND --bind $GRAPHIC_ELEMENTS_CACHE_DIR:/opt/nim/.cache --bind $GRAPHIC_ELEMENTS_WORK_DIR/tmp:/opt/nim/tmp --bind $GRAPHIC_ELEMENTS_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$GRAPHIC_ELEMENTS_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_INGEST_WORKERS --env NIM_TRITON_GRPC_PORT=8004 --env NIM_HTTP_TRITON_PORT=8030 --env NIM_TRITON_METRICS_PORT=8031"
wait_for_ingest_nim "graphic-elements" "$GRAPHIC_ELEMENTS_PORT" || exit 1

export NIM_TRITON_EXTRA_ARGS="${_INGEST_CUDA_ARGS} --grpc-port=8007"
start_nim_service "table-structure" "$TABLE_STRUCTURE_PORT" "$TABLE_STRUCTURE_GPU_ID" \
    "table-structure.sif" \
    "$NVML_BIND --bind $TABLE_STRUCTURE_CACHE_DIR:/opt/nim/.cache --bind $TABLE_STRUCTURE_WORK_DIR/tmp:/opt/nim/tmp --bind $TABLE_STRUCTURE_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$TABLE_STRUCTURE_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_INGEST_WORKERS --env NIM_TRITON_GRPC_PORT=8007 --env NIM_HTTP_TRITON_PORT=8040 --env NIM_TRITON_METRICS_PORT=8041"
wait_for_ingest_nim "table-structure" "$TABLE_STRUCTURE_PORT" || exit 1

export NIM_TRITON_EXTRA_ARGS="${_INGEST_CUDA_ARGS} --grpc-port=8010"
start_nim_service "paddle-ocr" "$PADDLE_OCR_PORT" "$PADDLE_OCR_GPU_ID" \
    "paddle.sif" \
    "$NVML_BIND --bind $PADDLE_OCR_CACHE_DIR:/opt/nim/.cache --bind $PADDLE_OCR_WORK_DIR/tmp:/opt/nim/tmp --bind $PADDLE_OCR_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$PADDLE_OCR_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_INGEST_WORKERS --env NIM_TRITON_GRPC_PORT=8010 --env NIM_HTTP_TRITON_PORT=8050 --env NIM_TRITON_METRICS_PORT=8051"
wait_for_ingest_nim "paddle-ocr" "$PADDLE_OCR_PORT" || exit 1

unset NIM_TRITON_EXTRA_ARGS

echo ""
echo "✅ All Ingest NIMs ready"
echo "   Monitor: tail -f $RAG_LOGS_DIR/page-elements.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/graphic-elements.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/table-structure.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/paddle-ocr.log"
