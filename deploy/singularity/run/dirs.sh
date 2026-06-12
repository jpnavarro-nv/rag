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
# transient — they are derived from RAG_RUNTIME_DIR and managed by config.sh
# via .current_exec. Do NOT add session-specific paths here.

# ==============================================================================
# Effective user identity (resilient against scrubbed-env Slurm jobs)
# ==============================================================================
# $USER can be empty inside `srun --export=NONE`, singularity `--contain`, or
# some Slurm prologue setups.  Fall back to /etc/passwd lookup via `id -un`,
# and finally to a numeric `uidNNNN` form if the user has no NSS entry.
export RAG_USER="${USER:-$(id -un 2>/dev/null)}"
export RAG_USER="${RAG_USER:-uid$(id -u)}"

# ==============================================================================
# Container infrastructure (shared across all users and exec sessions)
# ==============================================================================
export RAG_IMAGES_DIR="$RAG_BASE_DIR/containers/images"
export RAG_CACHE_DIR="$RAG_BASE_DIR/containers/cache"
export SINGULARITY_CACHEDIR="$RAG_CACHE_DIR"

# ==============================================================================
# Persistent databases (shared across all exec sessions)
# ==============================================================================
# DB layer (MinIO/Milvus/etcd) data. Defaults under $RAG_BASE_DIR; override the env
# to pin it to node-local disk, e.g. RAG_DB_DIR=/tmp/rag-db ./submit.sh.
export RAG_DB_DIR="${RAG_DB_DIR:-$RAG_BASE_DIR/db}"
export RAG_MILVUS_DATA_DIR="$RAG_DB_DIR/milvus-data"
export RAG_MILVUS_CONFIG_DIR="$RAG_DB_DIR/milvus-configs"
export RAG_ETCD_DATA_DIR="$RAG_DB_DIR/etcd-data"
export RAG_MINIO_DATA_DIR="$RAG_DB_DIR/minio-data"

# ==============================================================================
# NIM model caches (persistent — model weights survive across exec sessions)
# ==============================================================================
export RAG_MODELS_DIR="$RAG_BASE_DIR/models"

# ==============================================================================
# Per-user session root (multi-tenant log/runtime isolation)
# ==============================================================================
# Each user's exec sessions, .current_exec pointer, and Slurm outputs live
# under $RAG_SESSIONS_DIR/$RAG_USER/.  The dir itself is created (and chmod'd)
# by the script that needs it; this file only declares the path.
export RAG_SESSIONS_DIR="$RAG_BASE_DIR/sessions"
export RAG_EMBEDDING_CACHE_DIR="$RAG_MODELS_DIR/embedding-cache"
export RAG_RANKING_CACHE_DIR="$RAG_MODELS_DIR/ranking-cache"
export RAG_LLM_CACHE_DIR="$RAG_MODELS_DIR/llm-cache"
export RAG_VLM_CACHE_DIR="$RAG_MODELS_DIR/vlm-cache"
export RAG_PAGE_ELEMENTS_CACHE_DIR="$RAG_MODELS_DIR/page-elements-cache"
export RAG_GRAPHIC_ELEMENTS_CACHE_DIR="$RAG_MODELS_DIR/graphic-elements-cache"
export RAG_TABLE_STRUCTURE_CACHE_DIR="$RAG_MODELS_DIR/table-structure-cache"
export RAG_PADDLE_OCR_CACHE_DIR="$RAG_MODELS_DIR/paddle-ocr-cache"
