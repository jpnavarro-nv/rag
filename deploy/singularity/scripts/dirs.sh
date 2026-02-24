#!/bin/bash
# Canonical directory layout for the RAG Singularity deployment.
#
# Source this file AFTER RAG_BASE_DIR is set. This file is intentionally
# silent: no echo, no mkdir, no side effects — only variable declarations.
# Directory creation is the responsibility of the script that sources this file.
#
# All paths are permanent (persist across exec sessions), derived solely
# from RAG_BASE_DIR.
#
# OUT OF SCOPE: Runtime/exec-session paths (logs, pids, nim-work, tmp) are
# transient — they are derived from RAG_RUNTIME_DIR and managed by 00-config.sh
# via .current_exec. Do NOT add session-specific paths here.

# ==============================================================================
# Container infrastructure
# ==============================================================================
export RAG_IMAGES_DIR="$RAG_BASE_DIR/containers/images"
export RAG_CACHE_DIR="$RAG_BASE_DIR/containers/cache"
export APPTAINER_CACHEDIR="$RAG_CACHE_DIR"

# ==============================================================================
# Persistent databases (shared across all exec sessions)
# ==============================================================================
export RAG_DB_DIR="$RAG_BASE_DIR/db"
export RAG_MILVUS_DATA_DIR="$RAG_DB_DIR/milvus-data"
export RAG_MILVUS_CONFIG_DIR="$RAG_DB_DIR/milvus-configs"
export RAG_ETCD_DATA_DIR="$RAG_DB_DIR/etcd-data"
export RAG_MINIO_DATA_DIR="$RAG_DB_DIR/minio-data"

# ==============================================================================
# Apptainer working directory (permanent fallback when no exec session is active)
# Used by 00-config.sh as APPTAINER_TMPDIR fallback for 01-start-infrastructure.sh,
# which sources 00-config.sh before the exec dir exists.
# ==============================================================================
export RAG_APPTAINER_TMP_DIR="$RAG_BASE_DIR/.apptainer-tmp"

# ==============================================================================
# NIM model caches (persistent — model weights survive across exec sessions)
# ==============================================================================
export RAG_MODELS_DIR="$RAG_BASE_DIR/models"
export RAG_EMBEDDING_CACHE_DIR="$RAG_MODELS_DIR/embedding-cache"
export RAG_RANKING_CACHE_DIR="$RAG_MODELS_DIR/ranking-cache"
export RAG_LLM_CACHE_DIR="$RAG_MODELS_DIR/llm-cache"
export RAG_VLM_CACHE_DIR="$RAG_MODELS_DIR/vlm-cache"
export RAG_PAGE_ELEMENTS_CACHE_DIR="$RAG_MODELS_DIR/page-elements-cache"
export RAG_GRAPHIC_ELEMENTS_CACHE_DIR="$RAG_MODELS_DIR/graphic-elements-cache"
export RAG_TABLE_STRUCTURE_CACHE_DIR="$RAG_MODELS_DIR/table-structure-cache"
export RAG_PADDLE_OCR_CACHE_DIR="$RAG_MODELS_DIR/paddle-ocr-cache"
