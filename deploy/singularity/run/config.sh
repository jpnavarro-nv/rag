#!/bin/bash
# Configuration file for RAG Singularity deployment
# Source this file before running other scripts.
#
# 01-start-infrastructure.sh must run first — it creates the exec directory
# and writes its path to $RAG_BASE_DIR/.current_exec.
#
# Required environment variables (set before sourcing):
#   NGC_API_KEY     - NVIDIA NGC API key for NIMs
#   RAG_BASE_DIR    - Base directory for all RAG data (REQUIRED — no default)

# ==============================================================================
# Permanent Base Directories
# ==============================================================================
if [ -z "${RAG_BASE_DIR:-}" ]; then
    echo "ERROR: RAG_BASE_DIR is not set." >&2
    echo "" >&2
    echo "Set it explicitly before running:" >&2
    echo "  export RAG_BASE_DIR=/path/to/rag-workdir" >&2
    echo "" >&2
    echo "Use a fast local or parallel filesystem (NVMe scratch, GPFS, BeeGFS)." >&2
    echo "Avoid NFS home directories — they significantly slow down model loading." >&2
    return 1 2>/dev/null || exit 1
fi

# All permanent paths (containers, db, models) are defined centrally in dirs.sh
source "$(dirname "${BASH_SOURCE[0]}")/dirs.sh"

# ==============================================================================
# Current Execution Directory (written by 01-start-infrastructure.sh)
# Each ./01 run creates exec_YYYY_MM_DD_{N,SLURM_JOB_ID} under the per-user
# sessions dir and records it here.  The pointer is per-user so concurrent
# users on the same node never collide.
# ==============================================================================
_CURRENT_EXEC_FILE="$RAG_SESSIONS_DIR/$RAG_USER/.current_exec"
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
# Singularity Configuration
# ==============================================================================
# SINGULARITY_CACHEDIR is defined in dirs.sh (sourced above).
#
# SINGULARITY_TMPDIR must point to a local POSIX filesystem (not Lustre/NFS).
# Singularity uses it to create the --nv driver-libs bundle and other namespace
# structures that require overlayfs/hard-link support unavailable on Lustre.
# Using the exec-session tmp (on Lustre) breaks --nv → Milvus fails to start.
export SINGULARITY_TMPDIR=/tmp

# ==============================================================================
# Create Permanent Directories
# ==============================================================================
mkdir -p "$RAG_IMAGES_DIR"
mkdir -p "$RAG_CACHE_DIR"
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
# 127.0.0.1 (not localhost): on these HPC nodes `getent hosts localhost` returns ::1
# first, and the ingestor/rag-server MinIO+Milvus clients then connect over [::1],
# where the socket goes CLOSE-WAIT and urllib3 hangs on read-timeout×retries — the
# ~900–1850s ingestor startup stall (FORENSIC DUMP job 360948: CLOSE-WAIT [::1]:9010).
# These services bind 0.0.0.0, so 127.0.0.1 is always reachable and bypasses ::1.
export MINIO_HOST=127.0.0.1
export MINIO_PORT=9010
export MINIO_CONSOLE_PORT=9011
export MILVUS_HOST=127.0.0.1
export MILVUS_PORT=19530

# Hard-set (not :-default): the ingestor always runs on THIS node and the
# readiness probe in 06 must hit the local server. submit.sh uses sbatch
# --export=ALL, so a stale INGESTOR_HOST from the login shell (e.g. a leftover
# `export INGESTOR_HOST=gaiabXXnYY` from a debug session) would otherwise leak
# into the job; 06's `${INGESTOR_HOST:-127.0.0.1}` is a NO-OP when the var is
# already set, so wait_for_ingestor would curl the WRONG node → exit=7 for
# 1800s → teardown of a perfectly healthy server (job 360984: server up on
# gaiab02n02, probe checking gaiab01n03). Same NO-OP trap 676b2d0 fixed for
# MinIO/Milvus. Overriding here is the single source of truth.
export INGESTOR_HOST=127.0.0.1

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
