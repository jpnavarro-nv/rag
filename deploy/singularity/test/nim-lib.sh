#!/bin/bash
# nim-lib.sh - Shared library for NIM startup scripts
# Source this file after 00-config.sh
#
# Provides:
#   - Port variables (overridable via env)
#   - GPU assignment variables (overridable via env)
#   - start_nim_service() function

# ==============================================================================
# NIM Ports — match Docker Compose host:container mappings
# ==============================================================================
# LLM/VLM NIMs (nim_llm_sdk/vLLM): port passed as --port to start_server.sh
# Triton NIMs:                       port set via NIM_HTTP_API_PORT env var
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
RANKING_PORT=${RANKING_PORT:-1976}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-1977}
PAGE_ELEMENTS_PORT=${PAGE_ELEMENTS_PORT:-8000}
GRAPHIC_ELEMENTS_PORT=${GRAPHIC_ELEMENTS_PORT:-8003}
TABLE_STRUCTURE_PORT=${TABLE_STRUCTURE_PORT:-8006}
PADDLE_OCR_PORT=${PADDLE_OCR_PORT:-8009}

# ==============================================================================
# GPU Distribution — 4-GPU strategy
# ==============================================================================
# GPU 0: Retrieval  (Embedding, Ranking)
# GPU 1: Generation (LLM - 49B)
# GPU 2: Processing (YOLOX x3, PaddleOCR)
# GPU 3: Vision     (VLM)
EMBEDDING_GPU_ID=${EMBEDDING_MS_GPU_ID:-0}
RANKING_GPU_ID=${RANKING_MS_GPU_ID:-0}
LLM_GPU_ID=${LLM_MS_GPU_ID:-1}
VLM_GPU_ID=${VLM_MS_GPU_ID:-3}
PAGE_ELEMENTS_GPU_ID=${YOLOX_MS_GPU_ID:-2}
GRAPHIC_ELEMENTS_GPU_ID=${YOLOX_GRAPHICS_MS_GPU_ID:-2}
TABLE_STRUCTURE_GPU_ID=${YOLOX_TABLE_MS_GPU_ID:-2}
PADDLE_OCR_GPU_ID=${OCR_MS_GPU_ID:-2}

# ==============================================================================
# start_nim_service — launches a NIM as a Singularity instance
# ==============================================================================
# Usage: start_nim_service NAME PORT GPU IMAGE [SINGULARITY_OPTS] [STARTSCRIPT_CMD]
#   NAME:             service name (instance will be named nim-NAME)
#   PORT:             host port the NIM will listen on
#   GPU:              CUDA_VISIBLE_DEVICES value
#   IMAGE:            .sif filename (relative to RAG_IMAGES_DIR)
#   SINGULARITY_OPTS: extra --env flags for singularity instance start (optional)
#   STARTSCRIPT_CMD:  command passed after instance name to %startscript "$@" (optional)
#                     Used as workaround for nim_llm_sdk NIMs before image rebuild.
start_nim_service() {
    local name=$1
    local port=$2
    local gpu_id=$3
    local image=$4
    local singularity_opts="${5:-}"
    local startscript_cmd="${6:-}"

    local instance_name="nim-${name}"
    local log_file="$RAG_LOGS_DIR/${name}.log"

    if singularity instance list | grep -q "^${instance_name}"; then
        echo "   ⊘  $name already running (instance: $instance_name)"
        return 0
    fi

    echo "   Starting $name on port $port, GPU $gpu_id..."

    singularity instance start \
      --nv \
      --env CUDA_VISIBLE_DEVICES=$gpu_id \
      --env NGC_API_KEY=$NGC_API_KEY \
      --env NVIDIA_API_KEY=$NGC_API_KEY \
      $singularity_opts \
      "$RAG_IMAGES_DIR/$image" \
      "$instance_name" \
      $startscript_cmd \
      > "$log_file" 2>&1

    if singularity instance list | grep -q "^${instance_name}"; then
        echo "   ✅ $name started (instance: $instance_name, log: $log_file)"
        return 0
    else
        echo "   ❌ $name failed to start — check: tail -20 $log_file"
        return 1
    fi
}
