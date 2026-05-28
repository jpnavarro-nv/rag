#!/bin/bash
# ==============================================================================
# Slurm batch job: RAG Blueprint full setup
# ==============================================================================
# Runs the complete startup sequence (01–09) asynchronously on a GPU node.
# The job executes sequentially: each script must succeed before the next runs.
# Progress is written to the Slurm output file; monitor it with:
#
#   tail -f rag-setup-<JOBID>.log
#
# Submit (recommended — vars from current shell, no leak via scontrol show job):
#   source ~/.rag-env             # exports NGC_API_KEY and RAG_BASE_DIR
#   cd deploy/singularity/run
#   sbatch --export=ALL ./submit-job.sh
#
# Or, fully explicit (vars become visible in scontrol show job):
#   sbatch --export=ALL,NGC_API_KEY=$NGC_API_KEY,RAG_BASE_DIR=$RAG_BASE_DIR \
#          submit-job.sh
#
# Optional overrides at submission time:
#   --output=/custom/path/slurm-%j.log
#   --time=10:00:00
#
# Stop the running stack with:
#   scancel <JOBID>      # triggers graceful 99-stop-all.sh via trap
# ==============================================================================

#SBATCH --job-name=rag-setup
#SBATCH --partition=gpu
#SBATCH --account=llm-tic
#SBATCH --nodes=1
#SBATCH --gres=gpu:4
#SBATCH --time=08:00:00        # allow 60+ min for LLM 49B first-load weight download
#SBATCH --output=rag-setup-%j.log

# ==============================================================================
# Validate required environment variables
# ==============================================================================
if [ -z "${NGC_API_KEY}" ]; then
    echo "ERROR: NGC_API_KEY is not set."
    echo ""
    echo "Submit with:"
    echo "  export NGC_API_KEY=\"nvapi-...\""
    echo "  sbatch --export=ALL,NGC_API_KEY=\$NGC_API_KEY,RAG_BASE_DIR=\$RAG_BASE_DIR submit-job.sh"
    exit 1
fi

if [ -z "${RAG_BASE_DIR}" ]; then
    echo "ERROR: RAG_BASE_DIR is not set."
    echo ""
    echo "Submit with:"
    echo "  export RAG_BASE_DIR=\"/path/to/rag-workdir\""
    echo "  sbatch --export=ALL,NGC_API_KEY=\$NGC_API_KEY,RAG_BASE_DIR=\$RAG_BASE_DIR submit-job.sh"
    exit 1
fi

if [ ! -d "${RAG_BASE_DIR}" ]; then
    echo "ERROR: RAG_BASE_DIR does not exist or is not a directory: ${RAG_BASE_DIR}"
    exit 1
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

# Resolve the Slurm output path the user can tail.  --output=rag-setup-%j.log
# is relative to SLURM_SUBMIT_DIR (the dir where `sbatch` was invoked from), so
# this same path appears in the early banner and in the READY banner later.
SLURM_OUT_PATH="${SLURM_SUBMIT_DIR:-$(pwd)}/rag-setup-${SLURM_JOB_ID}.log"

echo "======================================================"
echo "  RAG Blueprint — Slurm Setup Job"
echo "======================================================"
echo "  Job ID   : ${SLURM_JOB_ID}"
echo "  Node     : ${SLURMD_NODENAME}"
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
if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -n "$RAG_LOGS_DIR" ]; then
    ln -sf "$SLURM_SUBMIT_DIR/rag-setup-${SLURM_JOB_ID}.log" \
           "$RAG_LOGS_DIR/slurm.out" 2>/dev/null || true
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

# Graceful shutdown on scancel / SIGTERM / SIGINT.
# Disarm trap on first call so re-entry during 99-stop-all.sh is a no-op.
cleanup() {
    trap - SIGTERM SIGINT EXIT
    echo ""
    echo "[$(date -Iseconds)] Caught termination signal — running 99-stop-all.sh..."
    bash "$SCRIPT_DIR/99-stop-all.sh" || true
    echo "[$(date -Iseconds)] RAG stack stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

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
