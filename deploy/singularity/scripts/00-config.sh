#!/bin/bash
# Configuration file for RAG Singularity deployment
# Source this file before running other scripts.
#
# 01-start-infrastructure.sh must run first — it creates the exec directory
# and writes its path to $RAG_BASE_DIR/.current_exec.
#
# Required environment variables (set before sourcing):
#   NGC_API_KEY     - NVIDIA NGC API key for NIMs
#   RAG_BASE_DIR    - Base directory for all RAG data (optional, defaults to $HOME/rag-test)

# ==============================================================================
# Permanent Base Directories
# ==============================================================================
export RAG_BASE_DIR=${RAG_BASE_DIR:-$HOME/rag-test}

# All permanent paths (containers, db, models) are defined centrally in dirs.sh
source "$(dirname "${BASH_SOURCE[0]}")/dirs.sh"

# ==============================================================================
# Current Execution Directory (written by 01-start-infrastructure.sh)
# Each ./01 run creates exec_YYYY_MM_DD_N and records it here.
# ==============================================================================
_CURRENT_EXEC_FILE="$RAG_BASE_DIR/.current_exec"
if [ -f "$_CURRENT_EXEC_FILE" ]; then
    export RAG_EXEC_DIR=$(cat "$_CURRENT_EXEC_FILE")
    export RAG_RUNTIME_DIR=$RAG_EXEC_DIR/runtime
    export RAG_LOGS_DIR=$RAG_EXEC_DIR/logs
    export RAG_TMP_DIR=$RAG_EXEC_DIR/tmp
else
    export RAG_EXEC_DIR=""
    export RAG_RUNTIME_DIR=""
    export RAG_LOGS_DIR=""
    export RAG_TMP_DIR=""
fi

# ==============================================================================
# Apptainer/Singularity Configuration
# ==============================================================================
# APPTAINER_CACHEDIR is defined in dirs.sh (sourced above).
# APPTAINER_TMPDIR uses the exec-session tmp when available; falls back to the
# permanent RAG_APPTAINER_TMP_DIR (also from dirs.sh) for the window before
# 01-start-infrastructure.sh creates the exec dir and writes .current_exec.
export APPTAINER_TMPDIR=${RAG_TMP_DIR:-$RAG_APPTAINER_TMP_DIR}

# ==============================================================================
# Create Permanent Directories
# ==============================================================================
mkdir -p "$RAG_IMAGES_DIR"
mkdir -p "$RAG_CACHE_DIR"
mkdir -p "$RAG_APPTAINER_TMP_DIR"
mkdir -p "$RAG_MILVUS_DATA_DIR" "$RAG_MILVUS_CONFIG_DIR" "$RAG_ETCD_DATA_DIR" "$RAG_MINIO_DATA_DIR"
mkdir -p "$RAG_MODELS_DIR"

# ==============================================================================
# Create Exec Directories (only when an exec dir is active)
# ==============================================================================
if [ -n "$RAG_EXEC_DIR" ]; then
    mkdir -p "$RAG_LOGS_DIR"
    mkdir -p "$RAG_TMP_DIR"
    mkdir -p "$RAG_RUNTIME_DIR/pids"
    mkdir -p "$RAG_RUNTIME_DIR/nim-work"
    mkdir -p "$RAG_RUNTIME_DIR/ingestor-temp"
    mkdir -p "$RAG_RUNTIME_DIR/ingestor-venv-bin"
    mkdir -p "$RAG_RUNTIME_DIR/nv-ingest-data"
fi

# ==============================================================================
# Network Configuration
# ==============================================================================
export ETCD_HOST=localhost
export ETCD_PORT=2379
export MINIO_HOST=localhost
export MINIO_PORT=9010
export MINIO_CONSOLE_PORT=9011
export MILVUS_HOST=localhost
export MILVUS_PORT=19530

# ==============================================================================
# MinIO Credentials
# ==============================================================================
export MINIO_ROOT_USER=minioadmin
export MINIO_ROOT_PASSWORD=minioadmin

# ==============================================================================
# NGC API Key
# ==============================================================================
export NGC_API_KEY=${NGC_API_KEY:-""}

# ==============================================================================
# Validation
# ==============================================================================
echo "✅ Configuration loaded"
echo ""
echo "Permanent:"
echo "   Base:     $RAG_BASE_DIR"
echo "   Images:   $RAG_IMAGES_DIR"
echo "   DB:       $RAG_DB_DIR"
if [ -n "$RAG_EXEC_DIR" ]; then
    echo ""
    echo "Exec: $(basename $RAG_EXEC_DIR)"
    echo "   Logs:    $RAG_LOGS_DIR"
    echo "   Runtime: $RAG_RUNTIME_DIR"
else
    echo ""
    echo "⚠️  No active exec directory (run 01-start-infrastructure.sh first)"
fi
echo ""

if [ -z "$NGC_API_KEY" ]; then
    echo "⚠️  WARNING: NGC_API_KEY not set"
    echo "   NIMs will not start without it. Set with:"
    echo "   export NGC_API_KEY='your-key-here'"
else
    echo "✅ NGC_API_KEY: ${NGC_API_KEY:0:10}...${NGC_API_KEY: -4}"
fi
echo ""
