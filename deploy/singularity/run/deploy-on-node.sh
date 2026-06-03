#!/bin/bash
# ==============================================================================
# Slurm batch job: RAG Blueprint full setup
# ==============================================================================
# Runs the complete startup sequence (01–09) on a GPU node, then enters a
# supervisor loop that keeps the stack alive until `scancel`.
#
# *** Recommended invocation: via the wrapper submit.sh ***
#
#   cd deploy/singularity/run && ./submit.sh
#
# The wrapper handles cluster auto-detection (account, partition, GPUs,
# walltime) and per-user log routing.  It supplies the site-specific
# `--account`, `--partition`, `--gres`, `--output` (and `--time` when set in
# the cluster conf) flags via the sbatch CLI — they intentionally are NOT
# hardcoded as #SBATCH directives here so the script stays portable.
#
# Direct `sbatch deploy-on-node.sh` still works, but you must supply the missing
# directives on the command line (or no job will start):
#
#   sbatch --account=ACCOUNT --partition=PART --gres=gpu:4 --export=ALL \
#          deploy-on-node.sh
#
# Stop the running stack with:
#   scancel <JOBID>      # triggers graceful 99-stop-all.sh via trap
# ==============================================================================

#SBATCH --job-name=rag-setup
#SBATCH --nodes=1

# ==============================================================================
# Validate required environment variables
# ==============================================================================
if [ -z "${NGC_API_KEY}" ]; then
    echo "ERROR: NGC_API_KEY is not set."
    echo ""
    echo "Run the wrapper from the login node:"
    echo "  export NGC_API_KEY=\"nvapi-...\""
    echo "  cd deploy/singularity/run && ./submit.sh"
    exit 1
fi

if [ -z "${RAG_BASE_DIR}" ]; then
    echo "ERROR: RAG_BASE_DIR is not set."
    echo ""
    echo "The wrapper sources RAG_BASE_DIR from clusters/<name>.conf."
    echo "Run from the login node:"
    echo "  cd deploy/singularity/run && ./submit.sh"
    exit 1
fi

if [ ! -d "${RAG_BASE_DIR}" ]; then
    echo "ERROR: RAG_BASE_DIR does not exist or is not a directory: ${RAG_BASE_DIR}"
    exit 1
fi

# ==============================================================================
# Single-instance guard
# ==============================================================================
# The stack assumes ONE instance per RAG_BASE_DIR: db/ (etcd/MinIO/Milvus) and
# the fixed service ports are shared cluster-wide, so a second concurrent
# instance corrupts the shared db. Acquire a global lock (atomic `mkdir` on the
# shared FS) and refuse to start if another LIVE instance already holds it.
# Best-effort: if the lock dir can't be created for unrelated reasons, warn and
# proceed so a legitimate single run is never blocked. Concurrent multi-instance
# support is tracked as technical debt (see deploy-singularity-self-hosted.md).
RAG_LOCK="$RAG_BASE_DIR/.rag-active.lock"

_lock_holder_alive() {
    # Returns 0 if the JOBID recorded in the lock is still queued/running.
    # If squeue is unavailable we cannot prove the holder is dead → assume alive
    # (the safe choice: never silently stomp a possibly-running instance).
    local jobid="$1"
    [ -n "$jobid" ] || return 1
    command -v squeue >/dev/null 2>&1 || return 0
    squeue -h -j "$jobid" 2>/dev/null | grep -q .
}

_write_lock_info() {
    cat > "$RAG_LOCK/info" <<EOF
JOBID=${SLURM_JOB_ID:-}
NODE=$(hostname)
USER=${USER:-$(id -un)}
STARTED_AT=$(date -Iseconds)
EOF
}

_reject_second_instance() {
    local info="$RAG_LOCK/info"
    local h_job h_node h_user h_since
    h_job=$(sed -n 's/^JOBID=//p'      "$info" 2>/dev/null)
    h_node=$(sed -n 's/^NODE=//p'      "$info" 2>/dev/null)
    h_user=$(sed -n 's/^USER=//p'      "$info" 2>/dev/null)
    h_since=$(sed -n 's/^STARTED_AT=//p' "$info" 2>/dev/null)
    echo ""
    echo "ERRO: já existe uma instância do RAG em execução para esta base:"
    echo "      RAG_BASE_DIR = $RAG_BASE_DIR"
    echo "      job=${h_job:-?}  nó=${h_node:-?}  usuário=${h_user:-?}  desde=${h_since:-?}"
    echo ""
    echo "Só é suportada UMA instância por RAG_BASE_DIR (db/ e portas são"
    echo "compartilhados). Pare a instância ativa antes de subir outra:"
    echo "      scancel ${h_job:-<JOBID>}"
    echo ""
    exit 1
}

if mkdir "$RAG_LOCK" 2>/dev/null; then
    _write_lock_info
    echo "Single-instance lock adquirido: $RAG_LOCK"
elif [ -d "$RAG_LOCK" ]; then
    _holder_job=$(sed -n 's/^JOBID=//p' "$RAG_LOCK/info" 2>/dev/null)
    if _lock_holder_alive "$_holder_job"; then
        _reject_second_instance
    fi
    # Stale lock (holder gone) → reclaim once.
    echo "Lock obsoleto (job ${_holder_job:-?} não está mais ativo) — recuperando..."
    rm -rf "$RAG_LOCK"
    if mkdir "$RAG_LOCK" 2>/dev/null; then
        _write_lock_info
        echo "Single-instance lock readquirido: $RAG_LOCK"
    else
        # Lost a race with another acquirer → treat as live, refuse.
        _reject_second_instance
    fi
else
    # mkdir failed but no dir present → FS/permission oddity. Degrade gracefully.
    echo "AVISO: não foi possível criar o lock ($RAG_LOCK) — seguindo sem guard de instância única."
    RAG_LOCK=""   # mark as not-held so cleanup() won't touch a foreign lock
fi

# ==============================================================================
# Reduce polling output for batch logs
# 04-wait-nim-models.sh defaults to CHECK_INTERVAL=2 (noisy in batch).
# ==============================================================================
export CHECK_INTERVAL=15

# ==============================================================================
# Job information
# ==============================================================================
# Slurm copies the job script to /var/spool/slurmd/job<ID>/ on the compute node,
# so BASH_SOURCE points to the copy — not to where 01-09 live on shared FS.
# SLURM_SUBMIT_DIR is the directory the user ran `sbatch` from; use it when
# present, fall back to BASH_SOURCE for direct (non-sbatch) invocation.
SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Resolve the actual Slurm StdOut path — authoritative regardless of how the
# wrapper passed --output.  Falls back to Slurm's default convention if
# scontrol is unavailable or fails (e.g. very early during job start-up).
SLURM_OUT_PATH=$(scontrol show job "$SLURM_JOB_ID" -o 2>/dev/null \
                 | grep -oP 'StdOut=\K\S+' || true)
if [ -z "$SLURM_OUT_PATH" ]; then
    SLURM_OUT_PATH="${SLURM_SUBMIT_DIR:-$(pwd)}/slurm-${SLURM_JOB_ID}.out"
fi

echo "======================================================"
echo "  RAG Blueprint — Slurm Setup Job"
echo "======================================================"
echo "  Job ID   : ${SLURM_JOB_ID}"
echo "  Node     : ${SLURMD_NODENAME}"
echo "  User     : ${USER:-$(id -un)}"
echo "  GPUs     : ${SLURM_GPUS_ON_NODE:-${CUDA_VISIBLE_DEVICES}}"
echo "  Base dir : ${RAG_BASE_DIR}"
echo "  Started  : $(date)"
echo "------------------------------------------------------"
echo "  Follow   : tail -F ${SLURM_OUT_PATH}"
echo "  Stop     : scancel ${SLURM_JOB_ID}"
echo "======================================================"
echo ""

set -e

cd "$SCRIPT_DIR"

# ==============================================================================
# Graceful shutdown handler — define BEFORE installing the trap and BEFORE
# running 01-09, so a `scancel` during infrastructure startup still triggers
# 99-stop-all.sh instead of leaving orphan etcd/MinIO/Milvus/NIM processes
# in the cgroup.  Defensive: tolerates partial setup state (RAG_EXEC_DIR or
# RAG_RUNTIME_DIR may not yet exist if scancel arrives during 01).
# ==============================================================================
cleanup() {
    trap - SIGTERM SIGINT EXIT
    echo ""
    echo "[$(date -Iseconds)] Caught termination signal — running 99-stop-all.sh..."
    if [ -x "$SCRIPT_DIR/99-stop-all.sh" ] || [ -f "$SCRIPT_DIR/99-stop-all.sh" ]; then
        bash "$SCRIPT_DIR/99-stop-all.sh" || true
    else
        echo "[$(date -Iseconds)] WARNING: 99-stop-all.sh not found at $SCRIPT_DIR — skipping graceful shutdown"
    fi
    # Release the single-instance lock — only if it belongs to this job (never
    # remove a lock held by another instance, e.g. after a degraded acquire).
    if [ -n "${RAG_LOCK:-}" ] && [ -n "${SLURM_JOB_ID:-}" ] && [ -f "$RAG_LOCK/info" ]; then
        if grep -qx "JOBID=$SLURM_JOB_ID" "$RAG_LOCK/info" 2>/dev/null; then
            rm -rf "$RAG_LOCK" 2>/dev/null || true
            echo "[$(date -Iseconds)] Single-instance lock released."
        fi
    fi
    echo "[$(date -Iseconds)] RAG stack stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "--- [1/9] Infrastructure (etcd, MinIO, Milvus) ---"
bash 01-start-infrastructure.sh

echo "--- [2/9] Redis ---"
bash 02-start-redis.sh

echo "--- [3/9] NIM models (fire and return) ---"
bash 03-start-nim-models.sh

echo "--- [4/9] Wait for NIM models to be ready ---"
bash 04-wait-nim-models.sh

echo "--- [5/9] NV-Ingest microservice ---"
bash 05-start-nv-ingest-ms.sh

echo "--- [6/9] Ingestor Server ---"
bash 06-start-ingest-server.sh

echo "--- [7/9] RAG Server ---"
bash 07-start-rag-server.sh

echo "--- [8/9] Frontend ---"
bash 08-start-frontend.sh

echo "--- [9/9] Validate all services ---"
bash 09-validate-all-services.sh

# ==============================================================================
# Post-setup: keep the job alive so Slurm's cgroup teardown does not kill the
# 15+ background services started by 01-08. Pattern adapted from
# nim-singularity/_nim-job.sh — supervisor loop + trap on SIGTERM/SIGINT.
# ==============================================================================

# Pick up RAG_EXEC_DIR / RAG_LOGS_DIR / RAG_RUNTIME_DIR (created by 01).
source "$SCRIPT_DIR/config.sh" >/dev/null

# Symlink the Slurm output into the per-exec logs dir for one-stop debugging.
# $SLURM_OUT_PATH was resolved at the top of this script via scontrol — it
# matches whatever the wrapper passed as --output (.out under sessions/$USER/
# in the standard flow) or Slurm's default (slurm-<JOBID>.out in submit dir).
if [ -n "$SLURM_OUT_PATH" ] && [ -n "$RAG_LOGS_DIR" ]; then
    ln -sf "$SLURM_OUT_PATH" "$RAG_LOGS_DIR/slurm.out" 2>/dev/null || true
fi

# Sourceable job metadata (NODE/PORT for monitoring, scancel, debugging).
if [ -n "$RAG_EXEC_DIR" ]; then
    cat > "$RAG_EXEC_DIR/job.env" <<EOF
SLURM_JOB_ID=$SLURM_JOB_ID
NODE=$(hostname)
USER=$USER
RAG_BASE_DIR=$RAG_BASE_DIR
RAG_EXEC_DIR=$RAG_EXEC_DIR
STARTED_AT=$(date -Iseconds)
FRONTEND_URL=http://$(hostname):3000
RAG_SERVER_URL=http://$(hostname):8081
INGESTOR_URL=http://$(hostname):8082
EOF
fi

echo ""
echo "============================================================"
echo "  RAG Blueprint READY"
echo "  Job ID    : $SLURM_JOB_ID"
echo "  Node      : $(hostname)"
echo "  Frontend  : http://$(hostname):3000"
echo "  RAG API   : http://$(hostname):8081"
echo "  Ingestor  : http://$(hostname):8082"
echo "  Logs      : $RAG_LOGS_DIR"
echo "  Job env   : $RAG_EXEC_DIR/job.env"
echo "  Stop      : scancel $SLURM_JOB_ID"
echo "============================================================"

# Supervisor: detect crashed services via PID files. If any critical service
# dies, log it and trigger graceful shutdown so the Slurm job ends FAILED
# rather than appearing healthy with a dead stack.
set +e
while true; do
    sleep 30
    for pid_file in "$RAG_RUNTIME_DIR/pids/"*.pid; do
        [ -f "$pid_file" ] || continue
        pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$pid" ] || continue
        if ! ps -p "$pid" > /dev/null 2>&1; then
            svc=$(basename "$pid_file" .pid)
            echo ""
            echo "[$(date -Iseconds)] CRITICAL: $svc (PID $pid) died. Triggering shutdown."
            cleanup
        fi
    done
done
