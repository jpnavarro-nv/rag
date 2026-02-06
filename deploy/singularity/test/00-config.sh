#!/bin/bash
# Configuration file for RAG Singularity test deployment
# Source this file before running other scripts
#
# Required environment variables (set before sourcing):
#   NGC_API_KEY     - NVIDIA NGC API key for NIMs
#   RAG_BASE_DIR    - Base directory for all RAG data (optional, defaults to $HOME/rag-test)

# ==============================================================================
# Base Directories
# ==============================================================================
# NOTE: On HPC cluster, set: export RAG_BASE_DIR=/gaia/nvidia/partner/rag
# For local testing, it defaults to $HOME/rag-test
export RAG_BASE_DIR=${RAG_BASE_DIR:-$HOME/rag-test}

# Derived directories
export RAG_IMAGES_DIR=$RAG_BASE_DIR/containers/images
export RAG_CACHE_DIR=$RAG_BASE_DIR/containers/cache
export RAG_RUNTIME_DIR=$RAG_BASE_DIR/runtime
export RAG_TMP_DIR=$RAG_BASE_DIR/tmp
export RAG_LOGS_DIR=$RAG_BASE_DIR/logs

# ==============================================================================
# Singularity Configuration
# ==============================================================================
# Configure Singularity cache and temp directories automatically
export SINGULARITY_CACHEDIR=$RAG_CACHE_DIR
export SINGULARITY_TMPDIR=$RAG_TMP_DIR

# ==============================================================================
# Create Required Directories
# ==============================================================================
mkdir -p $RAG_IMAGES_DIR
mkdir -p $RAG_CACHE_DIR
mkdir -p $RAG_TMP_DIR
mkdir -p $RAG_LOGS_DIR
mkdir -p $RAG_RUNTIME_DIR/{etcd-data,minio-data,milvus-data,milvus-logs,pids}

# ==============================================================================
# Network Configuration
# ==============================================================================
# All services run on localhost (Singularity uses host network)
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
echo "Directories:"
echo "   Base:       $RAG_BASE_DIR"
echo "   Images:     $RAG_IMAGES_DIR"
echo "   Cache:      $RAG_CACHE_DIR"
echo "   Tmp:        $RAG_TMP_DIR"
echo "   Runtime:    $RAG_RUNTIME_DIR"
echo "   Logs:       $RAG_LOGS_DIR"
echo ""
echo "Singularity:"
echo "   Cache dir:  $SINGULARITY_CACHEDIR"
echo "   Tmp dir:    $SINGULARITY_TMPDIR"
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "⚠️  WARNING: NGC_API_KEY not set"
    echo "   NIMs will not start without it. Set with:"
    echo "   export NGC_API_KEY='your-key-here'"
else
    echo "✅ NGC_API_KEY: ${NGC_API_KEY:0:10}...${NGC_API_KEY: -4}"
fi
echo ""
