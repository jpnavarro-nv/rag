#!/bin/bash
# Start Retrieval NIMs: Embedding + Ranking + LLM
# Required for all RAG query/generation workflows.
# Equivalent to Docker Compose profile "rag".
#
# Run standalone:  bash nim-retrieval.sh
# Or via full stack: bash 04-start-nim-models.sh
set -e

source "$(dirname "$0")/../config.sh"
source "$(dirname "$0")/nim-lib.sh"

if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

# Persistent cache dirs defined in dirs.sh; runtime work dirs are session-specific.
# /opt/nim/.cache    → model weights (persistent across sessions, large)
# /opt/nim/tmp       → manifest downloads (session-scoped, small)
# /opt/nim/workspace → NIM working files during init (session-scoped, small)
EMBEDDING_WORK_DIR="$RAG_RUNTIME_DIR/nim-work/embedding"
RANKING_WORK_DIR="$RAG_RUNTIME_DIR/nim-work/ranking"
mkdir -p "$RAG_EMBEDDING_CACHE_DIR" "$EMBEDDING_WORK_DIR/tmp" "$EMBEDDING_WORK_DIR/workspace"
mkdir -p "$RAG_RANKING_CACHE_DIR"   "$RANKING_WORK_DIR/tmp"   "$RANKING_WORK_DIR/workspace"
mkdir -p "$RAG_LLM_CACHE_DIR"       # nim_llm_sdk (non-Triton) — no tmp/workspace needed

# ==============================================================================
# Triton Python backend instance count patch
# ==============================================================================
# The embedding and ranking NIMs set instance_group { count: N } in config.pbtxt
# where N = nproc (e.g. 16), spawning 16 concurrent Python backend stubs.
# On Singularity SquashFS the stubs race on imports and exceed the 10s timeout.
#
# Fix: _watch_and_patch_triton (below) runs in background on the HOST, watching
# the bind-mounted /opt/nim/tmp for service_config.yaml (written last by the NIM
# when the model repo is complete).  When detected, it patches all config.pbtxt
# files to TRITON_INSTANCE_COUNT (default: 2) within the ~1.5s window before
# Triton reads them.  Works on every session (no persistent nim-work required).
#
# To force model-repo re-generation (e.g. after a NIM update):
#   rm -rf $EMBEDDING_WORK_DIR/tmp/run/triton-model-repository
#   rm -rf $RANKING_WORK_DIR/tmp/run/triton-model-repository
TRITON_INSTANCE_COUNT=${TRITON_INSTANCE_COUNT:-2}

_patch_triton_instances() {
    local repo_dir="$1"
    local count="$2"
    # Find all config.pbtxt files that have an instance_group with count > target
    find "$repo_dir" -name "config.pbtxt" 2>/dev/null | while read -r cfg; do
        if grep -q "count:" "$cfg" 2>/dev/null; then
            local current
            current=$(grep -m1 "count:" "$cfg" | tr -d ' ' | cut -d: -f2)
            if [ "${current:-0}" -gt "$count" ] 2>/dev/null; then
                sed -i "s/count: ${current}/count: ${count}/g" "$cfg"
                echo "   Patched $cfg: instance count ${current} → ${count}"
            fi
        fi
    done
}

# _watch_and_patch_triton: background host-side patcher for Triton Python stubs.
#
# The NIM generates the Triton model repository with instance_group { count: N }
# where N = nproc (e.g. 16).  On Singularity SquashFS, all N stubs import Python
# simultaneously, racing for I/O and exceeding the 10s health-check timeout.
#
# Fix: watch for service_config.yaml on the HOST (visible via the /opt/nim/tmp
# bind mount) — repository.py writes this file LAST, ~1.5s before Triton reads
# the config.pbtxt files.  Patch immediately after detection.
#
# Timeline observed in nemoretriever-embedding.log:
#   13:14:41.478  repository.py:770 — service_config.yaml written (repo done)
#   13:14:43.050  Triton starts loading models (reads config.pbtxt)
#   window ≈ 1.57s — patcher fires within 100ms, completes well before Triton reads
_watch_and_patch_triton() {
    local repo_dir="$1"
    local count="$2"
    local service_cfg="$repo_dir/service_config.yaml"
    local n=0
    while [ ! -f "$service_cfg" ]; do
        sleep 0.1
        n=$((n+1))
        if [ "$n" -gt 6000 ]; then return 0; fi  # 10-minute safety timeout
    done
    _patch_triton_instances "$repo_dir" "$count"
}

EMBEDDING_TRITON_REPO="$EMBEDDING_WORK_DIR/tmp/run/triton-model-repository"
RANKING_TRITON_REPO="$RANKING_WORK_DIR/tmp/run/triton-model-repository"

echo "=== Starting Retrieval NIMs ==="
echo "   Embedding:  localhost:$EMBEDDING_PORT  (GPU $EMBEDDING_GPU_ID)"
echo "   Ranking:    localhost:$RANKING_PORT  (GPU $RANKING_GPU_ID)"
echo "   LLM:        localhost:$LLM_PORT  (GPU $LLM_GPU_ID)"
echo ""

# Triton NIMs: singularity run (Docker entrypoint), port via NIM_HTTP_API_PORT
#
# NIM_HTTP_API_WORKERS: controls uvicorn HTTP workers only. It does NOT affect
# the Triton Python backend stub count — the NIM sets that from cpu_count()
# in bls_model_builder.py regardless of NIM_HTTP_API_WORKERS.  The thundering-
# herd fix is handled by _watch_and_patch_triton above.
_RETRIEVAL_WORKERS=${NIM_HTTP_API_WORKERS:-2}

# Launch background patchers before starting NIMs.  Each watcher detects
# service_config.yaml (written when the Triton model repo is complete) and
# immediately patches config.pbtxt instance_group counts to TRITON_INSTANCE_COUNT,
# within the ~1.5s window before Triton reads the files.
echo "   Launching Triton instance-count patchers (target: $TRITON_INSTANCE_COUNT)..."
_watch_and_patch_triton "$EMBEDDING_TRITON_REPO" "$TRITON_INSTANCE_COUNT" &
_watch_and_patch_triton "$RANKING_TRITON_REPO" "$TRITON_INSTANCE_COUNT" &

start_nim_service "nemoretriever-embedding" "$EMBEDDING_PORT" "$EMBEDDING_GPU_ID" \
    "nemoretriever-embedding.sif" \
    "$NVML_BIND --bind $RAG_EMBEDDING_CACHE_DIR:/opt/nim/.cache --bind $EMBEDDING_WORK_DIR/tmp:/opt/nim/tmp --bind $EMBEDDING_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$EMBEDDING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_RETRIEVAL_WORKERS --env NIM_TRITON_GRPC_PORT=9001 --env NIM_HTTP_TRITON_PORT=9000 --env NIM_TRITON_METRICS_PORT=9002"

start_nim_service "nemoretriever-ranking" "$RANKING_PORT" "$RANKING_GPU_ID" \
    "nemoretriever-ranking.sif" \
    "$NVML_BIND --bind $RAG_RANKING_CACHE_DIR:/opt/nim/.cache --bind $RANKING_WORK_DIR/tmp:/opt/nim/tmp --bind $RANKING_WORK_DIR/workspace:/opt/nim/workspace --env NIM_HTTP_API_PORT=$RANKING_PORT --env NIM_CACHE_PATH=/opt/nim/.cache --env NIM_HTTP_API_WORKERS=$_RETRIEVAL_WORKERS --env NIM_TRITON_GRPC_PORT=8011 --env NIM_HTTP_TRITON_PORT=8060 --env NIM_TRITON_METRICS_PORT=8061"

# nim_llm_sdk NIM: singularity exec with explicit start_server.sh --port
# --cleanenv + MPI suppression same as VLM (same family, same HPC issues)
LLM_OPTS="--cleanenv --bind $RAG_LLM_CACHE_DIR:/opt/nim/.cache --env NIM_CACHE_PATH=/opt/nim/.cache --env OMPI_MCA_pmix=^all --env OMPI_MCA_pml=ob1 --env PMIX_MCA_gds=^ds12,ds21 --env PMIX_MCA_psec=^munge"

start_nim_service "nim-llm" "$LLM_PORT" "$LLM_GPU_ID" \
    "nim-llm.sif" \
    "$LLM_OPTS" \
    "/opt/nim/start_server.sh --port $LLM_PORT"

echo ""
echo "✅ Retrieval NIMs launched"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nemoretriever-embedding.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nemoretriever-ranking.log"
echo "   Monitor: tail -f $RAG_LOGS_DIR/nim-llm.log"
echo ""
echo "⚠️  LLM (49B) loads in ~10-15 min. Embedding/Ranking ready in ~2 min."
