#!/bin/bash
# Submit a SLURM job that starts a vLLM LLM server on an exclusive compute node.
#
# Cluster is auto-detected from hostname (see clusters/*.conf).
# Each submission allocates 1 full node with all GPUs for 1 model.
# Multiple users can submit multiple jobs concurrently — even the same model.
# Stop with: scancel <job_id>
#
# Usage:
#   ./submit-llm-job.sh nemotron3-120b                # submit with defaults
#   ./submit-llm-job.sh qwen3-122b --time=48:00:00    # override SLURM time
#   ./submit-llm-job.sh --list                         # list available models
#   ./submit-llm-job.sh --help                         # usage help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Usage
# ==============================================================================
show_usage() {
    echo "Usage: ./submit-llm-job.sh [OPTIONS] MODEL [SBATCH_OPTIONS...]"
    echo ""
    echo "Submit a SLURM job that starts a vLLM LLM server on an exclusive node."
    echo "Each job allocates 1 node with all GPUs (cluster auto-detected)."
    echo ""
    echo "Options:"
    echo "  --list    List available models (from models.conf)"
    echo "  --help    Show this help"
    echo ""
    echo "Any extra arguments are forwarded to sbatch (e.g. --time=48:00:00)."
    echo ""
    echo "Run './submit-llm-job.sh --list' to see available models."
}

# ==============================================================================
# Parse arguments: first positional is MODEL, rest are sbatch overrides
# ==============================================================================
MODEL_KEY=""
SBATCH_EXTRA=()

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --list|-l)
            export LLM_BASE_DIR="${LLM_BASE_DIR:-/tmp}"
            source "$SCRIPT_DIR/llm-config.sh"
            list_models
            echo "Usage: ./submit-llm-job.sh MODEL [SBATCH_OPTIONS...]"
            exit 0
            ;;
        --*)
            SBATCH_EXTRA+=("$arg")
            ;;
        *)
            if [ -z "$MODEL_KEY" ]; then
                MODEL_KEY="$arg"
            else
                SBATCH_EXTRA+=("$arg")
            fi
            ;;
    esac
done

if [ -z "$MODEL_KEY" ]; then
    echo "ERROR: No model specified."
    echo ""
    show_usage
    exit 1
fi

# ==============================================================================
# Auto-detect cluster (sets LLM_BASE_DIR, SLURM_PARTITION, etc.)
# ==============================================================================
source "$SCRIPT_DIR/cluster-config.sh"
source "$SCRIPT_DIR/llm-config.sh"

# ==============================================================================
# Resolve model and verify SIF exists
# ==============================================================================
resolve_model "$MODEL_KEY"

if [ ! -f "$LLM_IMAGES_DIR/$SIF_NAME" ]; then
    echo "ERROR: SIF not found: $LLM_IMAGES_DIR/$SIF_NAME"
    echo ""
    echo "Run './build-llm-images.sh $MODEL_KEY' first."
    exit 1
fi

# ==============================================================================
# Ensure shared directories exist
# ==============================================================================
mkdir -p "$LLM_SESSIONS_DIR/$USER"

# ==============================================================================
# Submit SLURM job
# ==============================================================================
echo "Submitting vLLM job: $MODEL_KEY ($MODEL_DESC)"
echo "  SIF:   $LLM_IMAGES_DIR/$SIF_NAME"
echo "  Port:  $LLM_PORT"
echo ""

# Export the real script directory so the job script (which SLURM copies to
# /var/spool/slurmd/) can find llm-config.sh and other files on shared storage.
export LLM_SCRIPT_DIR="$SCRIPT_DIR"

# The --output path uses %j which SLURM expands to the job ID.
# We write to a flat path in the user dir (which exists) because the per-job
# subdirectory is created inside the job script — after SLURM opens stdout.
# The job script symlinks slurm.out into the per-job directory.
JOB_ID=$(sbatch \
    --parsable \
    --job-name="llm-${MODEL_KEY}" \
    --partition="$SLURM_PARTITION" \
    --account="$SLURM_ACCOUNT" \
    --nodes=1 \
    --gres="gpu:${SLURM_GPUS_PER_NODE}" \
    --time="$SLURM_TIME" \
    --output="$LLM_SESSIONS_DIR/$USER/llm-%j.out" \
    --export=ALL \
    "${SBATCH_EXTRA[@]}" \
    "$SCRIPT_DIR/_llm-job.sh" "$MODEL_KEY")

echo "Submitted batch job $JOB_ID"
echo ""
echo "Monitor:"
echo "  tail -f $LLM_SESSIONS_DIR/$USER/llm-${JOB_ID}.out"
echo ""
echo "Stop:"
echo "  scancel $JOB_ID"
echo ""
echo "List active LLMs:"
echo "  ./list-llms.sh"
