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
# HPC NVML fix — Triton NIMs (embedding, ranking, YOLOX, paddle) require
# libnvidia-ml.so.1 at startup. On RHEL/Rocky HPC hosts the lib lives in
# /usr/lib64/ but the Ubuntu-based NIM containers expect it in
# /usr/lib/x86_64-linux-gnu/. Singularity --nv does not auto-mount it.
# Bind it manually. Overridable via NVML_HOST_LIB env var.
# vLLM NIMs (VLM, LLM) do NOT need this — they don't call NVML at startup.
# ==============================================================================
_NVML_HOST_LIB="${NVML_HOST_LIB:-/usr/lib64/libnvidia-ml.so.1}"
if [ -f "$_NVML_HOST_LIB" ]; then
    NVML_BIND="--bind $_NVML_HOST_LIB:/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
else
    NVML_BIND=""
fi

# ==============================================================================
# start_nim_service — launches a NIM as a background process (singularity exec/run)
# ==============================================================================
# Usage: start_nim_service NAME PORT GPU IMAGE [SINGULARITY_OPTS] [EXEC_CMD]
#   NAME:             service name (PID saved to $RAG_RUNTIME_DIR/pids/NAME.pid)
#   PORT:             host port the NIM will listen on (for display/health checks)
#   GPU:              CUDA_VISIBLE_DEVICES value
#   IMAGE:            .sif filename (relative to RAG_IMAGES_DIR)
#   SINGULARITY_OPTS: extra flags for singularity (--cleanenv, --bind, --env, etc.)
#   EXEC_CMD:         if set → singularity exec IMAGE EXEC_CMD (nim_llm_sdk NIMs)
#                     if empty → singularity run IMAGE (Triton NIMs, uses Docker entrypoint)
#
# Output goes to $RAG_LOGS_DIR/NAME.log (full NIM stdout+stderr, not just the
# singularity launcher banner).
start_nim_service() {
    local name=$1
    local port=$2
    local gpu_id=$3
    local image=$4
    local singularity_opts="${5:-}"
    local exec_cmd="${6:-}"

    local pid_file="$RAG_RUNTIME_DIR/pids/${name}.pid"
    local log_file="$RAG_LOGS_DIR/${name}.log"

    # Check if already running via PID file
    if [ -f "$pid_file" ]; then
        local existing_pid
        existing_pid=$(cat "$pid_file")
        if ps -p "$existing_pid" > /dev/null 2>&1; then
            echo "   ⊘  $name already running (PID $existing_pid)"
            return 0
        fi
        rm -f "$pid_file"
    fi

    echo "   Starting $name on port $port, GPU $gpu_id..."

    # Clear log so tail -f is unambiguous
    > "$log_file"

    if [ -n "$exec_cmd" ]; then
        # nim_llm_sdk NIMs (VLM, LLM): explicit command, port via --port arg
        # shellcheck disable=SC2086
        singularity exec \
          --nv \
          --env CUDA_VISIBLE_DEVICES="$gpu_id" \
          --env NGC_API_KEY="$NGC_API_KEY" \
          --env NVIDIA_API_KEY="$NGC_API_KEY" \
          $singularity_opts \
          "$RAG_IMAGES_DIR/$image" \
          $exec_cmd \
          >> "$log_file" 2>&1 &
    else
        # Triton NIMs: use Docker entrypoint via singularity run
        # Port controlled by NIM_HTTP_API_PORT passed in singularity_opts
        # shellcheck disable=SC2086
        singularity run \
          --nv \
          --env CUDA_VISIBLE_DEVICES="$gpu_id" \
          --env NGC_API_KEY="$NGC_API_KEY" \
          --env NVIDIA_API_KEY="$NGC_API_KEY" \
          $singularity_opts \
          "$RAG_IMAGES_DIR/$image" \
          >> "$log_file" 2>&1 &
    fi

    local pid=$!
    echo "$pid" > "$pid_file"

    sleep 3
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "   ✅ $name started (PID $pid, port $port)"
        echo "      log: $log_file"
        return 0
    else
        echo "   ❌ $name failed to start"
        echo "      check: tail -20 $log_file"
        rm -f "$pid_file"
        return 1
    fi
}
