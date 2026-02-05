#!/bin/bash
# Configuration file for RAG Singularity test deployment
# Source this file before running other scripts

# Base directories
# NOTE: On HPC cluster, use: /gaia/nvidia/partner/rag
# For local testing, use a local path
export RAG_BASE_DIR=${RAG_BASE_DIR:-$HOME/rag-test}
export RAG_IMAGES_DIR=$RAG_BASE_DIR/containers/images
export RAG_RUNTIME_DIR=$RAG_BASE_DIR/runtime
export RAG_LOGS_DIR=$RAG_BASE_DIR/logs

# Create runtime directories
mkdir -p $RAG_RUNTIME_DIR/{etcd-data,minio-data,milvus-data,milvus-logs}
mkdir -p $RAG_LOGS_DIR

# Network configuration (adjust for your cluster)
export ETCD_HOST=localhost
export ETCD_PORT=2379
export MINIO_HOST=localhost
export MINIO_PORT=9010
export MINIO_CONSOLE_PORT=9011
export MILVUS_HOST=localhost
export MILVUS_PORT=19530

# MinIO credentials
export MINIO_ROOT_USER=minioadmin
export MINIO_ROOT_PASSWORD=minioadmin

# NGC API Key
export NGC_API_KEY=${NGC_API_KEY:-""}

echo "✅ Configuration loaded"
echo "   Images: $RAG_IMAGES_DIR"
echo "   Runtime: $RAG_RUNTIME_DIR"
echo "   Logs: $RAG_LOGS_DIR"
