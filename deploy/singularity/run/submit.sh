#!/bin/bash
# ==============================================================================
# Submit the RAG Blueprint as a Slurm batch job — fire-and-forget wrapper.
# ==============================================================================
# Runs on the login node, NOT inside a Slurm job.  Steps:
#   1. Validate NGC_API_KEY in the current shell
#   2. Auto-detect cluster (sources clusters/<name>.conf for RAG_BASE_DIR,
#      partition, account, GPUs-per-node, walltime)
#   3. mkdir per-user sessions dir under $RAG_BASE_DIR/sessions/$USER (chmod 700)
#   4. `sbatch --parsable ...` with site-specific flags supplied on the CLI
#   5. Print a banner with `tail -F` and `scancel` ready to copy — then exit
#
# Usage:
#   export NGC_API_KEY="nvapi-..."
#   cd deploy/singularity/run
#   ./submit.sh                          # auto-detect cluster
#   CLUSTER_NAME=lncc ./submit.sh        # force a specific cluster
#
# Any extra arguments are forwarded to sbatch (e.g. --time=04:00:00 to override
# the per-cluster default).
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Guard: this wrapper is for the login node — `sbatch` from inside a running
# job submits against the controller of the parent allocation, often with
# restricted partitions and confusing errors.  Warn if SLURM_JOB_ID is set.
# ==============================================================================
if [ -n "${SLURM_JOB_ID:-}" ]; then
    echo "WARN: SLURM_JOB_ID is set ($SLURM_JOB_ID) — you appear to be running"
    echo "      submit.sh from inside a compute-node job.  This is unusual; the"
    echo "      sbatch will be routed through the current allocation's controller."
    echo ""
fi

# ==============================================================================
# Validate NGC_API_KEY on the login node — fail BEFORE consuming queue time.
# (RAG_BASE_DIR is supplied by cluster-config.sh; no check needed here.)
# ==============================================================================
if [ -z "${NGC_API_KEY:-}" ]; then
    echo "ERROR: NGC_API_KEY is not set." >&2
    echo "" >&2
    echo "Export it in your shell before running ./submit.sh:" >&2
    echo "  export NGC_API_KEY=\"nvapi-...\"" >&2
    exit 1
fi

# ==============================================================================
# Auto-detect cluster — sources clusters/<name>.conf and exports
# RAG_BASE_DIR, SLURM_PARTITION, SLURM_ACCOUNT, SLURM_GPUS_PER_NODE,
# SLURM_TIME, CLUSTER_NAME, CLUSTER_GPU.
# ==============================================================================
# shellcheck disable=SC1091
source "$SCRIPT_DIR/cluster-config.sh"

# ==============================================================================
# Resolve effective $USER for the sessions dir (matches dirs.sh fallback chain)
# ==============================================================================
RAG_USER="${USER:-$(id -un 2>/dev/null)}"
RAG_USER="${RAG_USER:-uid$(id -u)}"

# ==============================================================================
# Validate writeability + create per-user sessions dir on shared filesystem
# ==============================================================================
if [ ! -d "$RAG_BASE_DIR" ]; then
    echo "ERROR: RAG_BASE_DIR does not exist: $RAG_BASE_DIR" >&2
    echo "Create it (or update clusters/${CLUSTER_NAME}.conf) before running." >&2
    exit 1
fi

if [ ! -w "$RAG_BASE_DIR" ]; then
    echo "ERROR: RAG_BASE_DIR is not writeable by '$RAG_USER': $RAG_BASE_DIR" >&2
    exit 1
fi

USER_SESSIONS_DIR="$RAG_BASE_DIR/sessions/$RAG_USER"
mkdir -p "$USER_SESSIONS_DIR"
chmod 700 "$USER_SESSIONS_DIR" 2>/dev/null || true

# ==============================================================================
# Build the sbatch command — site-specific values come from cluster-config.sh,
# multi-tenant log routing comes from USER_SESSIONS_DIR.  --export=ALL is
# baked in so NGC_API_KEY / RAG_BASE_DIR / etc. reach the compute node.
# ==============================================================================
SBATCH_ARGS=(
    --parsable
    --partition="$SLURM_PARTITION"
    --account="$SLURM_ACCOUNT"
    --gres="gpu:$SLURM_GPUS_PER_NODE"
    --output="$USER_SESSIONS_DIR/rag-setup-%j.out"
    --export=ALL
)

# SLURM_TIME is intentionally optional — empty means "no --time flag" so the
# partition's default/max applies (effectively unlimited within site policy).
if [ -n "${SLURM_TIME:-}" ]; then
    SBATCH_ARGS+=(--time="$SLURM_TIME")
fi

# Pass any extra CLI args through (e.g. --time=04:00:00 to override).
SBATCH_ARGS+=("$@")

echo ""
echo "Submitting RAG Blueprint to Slurm..."
echo "  Cluster   : $CLUSTER_NAME ($CLUSTER_GPU)"
echo "  Partition : $SLURM_PARTITION"
echo "  Account   : $SLURM_ACCOUNT"
echo "  GPUs      : $SLURM_GPUS_PER_NODE"
echo "  Walltime  : ${SLURM_TIME:-(partition default — no limit)}"
echo "  Base dir  : $RAG_BASE_DIR"
echo "  User      : $RAG_USER"
echo ""

JOB_ID=$(sbatch "${SBATCH_ARGS[@]}" "$SCRIPT_DIR/deploy-on-node.sh")
SLURM_OUT="$USER_SESSIONS_DIR/rag-setup-${JOB_ID}.out"

echo "======================================================"
echo "  RAG Blueprint — submitted"
echo "======================================================"
echo "  Job ID   : $JOB_ID"
echo "  Follow   : tail -F $SLURM_OUT"
echo "  Status   : squeue -j $JOB_ID"
echo "  Stop     : scancel $JOB_ID"
echo "======================================================"
echo ""
echo "The Slurm output file appears once the scheduler allocates a node."
echo "Look for 'RAG Blueprint READY' (~15-20 min) for the frontend/API URLs."
