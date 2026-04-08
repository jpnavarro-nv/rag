#!/bin/bash
# Submit a SLURM job that starts a NIM LLM server on an exclusive compute node.
#
# Each submission allocates 1 full node (4x A100 80GB) for 1 model.
# Multiple users can submit multiple jobs concurrently — even the same model.
# Stop with: scancel <job_id>
#
# Usage:
#   export NGC_API_KEY="nvapi-..."
#   export NIM_BASE_DIR="/path/to/shared/dir"
#
#   ./submit-nim-job.sh nemotron-49b                  # submit with defaults
#   ./submit-nim-job.sh qwen3-122b --time=48:00:00    # override SLURM time
#   ./submit-nim-job.sh --list                         # list available models
#   ./submit-nim-job.sh --help                         # usage help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Usage
# ==============================================================================
show_usage() {
    echo "Usage: ./submit-nim-job.sh [OPTIONS] MODEL [SBATCH_OPTIONS...]"
    echo ""
    echo "Submit a SLURM job that starts a NIM LLM server on an exclusive node."
    echo "Each job allocates 1 node with 4x A100 80GB GPUs."
    echo ""
    echo "Options:"
    echo "  --list    List available models (from models.conf)"
    echo "  --help    Show this help"
    echo ""
    echo "Any extra arguments are forwarded to sbatch (e.g. --time=48:00:00)."
    echo ""
    echo "Run './submit-nim-job.sh --list' to see available models."
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
            export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
            export NIM_BASE_DIR="${NIM_BASE_DIR:-/tmp}"
            source "$SCRIPT_DIR/nim-config.sh"
            list_models
            echo "Usage: ./submit-nim-job.sh MODEL [SBATCH_OPTIONS...]"
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
# Validate required environment variables
# ==============================================================================
if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo ""
    echo "Set it to the shared directory for NIM data:"
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

if [ -z "$NGC_API_KEY" ]; then
    echo "ERROR: NGC_API_KEY is not set."
    echo ""
    echo "Set it to your NVIDIA NGC API key:"
    echo "  export NGC_API_KEY=\"nvapi-...\""
    exit 1
fi

# ==============================================================================
# Source configuration
# ==============================================================================
source "$SCRIPT_DIR/nim-config.sh"

# ==============================================================================
# Resolve model and verify SIF exists
# ==============================================================================
resolve_model "$MODEL_KEY"

if [ ! -f "$NIM_IMAGES_DIR/$SIF_NAME" ]; then
    echo "ERROR: SIF not found: $NIM_IMAGES_DIR/$SIF_NAME"
    echo ""
    echo "Run './build-nim-images.sh $MODEL_KEY' first."
    exit 1
fi

# ==============================================================================
# Ensure shared directories exist
# ==============================================================================
mkdir -p "$NIM_SESSIONS_DIR/$USER"
mkdir -p "$NIM_MODELS_DIR/${MODEL_KEY}-cache"

# ==============================================================================
# Submit SLURM job
# ==============================================================================
echo "Submitting NIM job: $MODEL_KEY ($MODEL_DESC)"
echo "  SIF:   $NIM_IMAGES_DIR/$SIF_NAME"
echo "  Port:  $LLM_PORT"
echo "  GPUs:  $LLM_GPU_ID"
echo ""

# Export the real script directory so the job script (which SLURM copies to
# /var/spool/slurmd/) can find nim-config.sh and other files on shared storage.
export NIM_SCRIPT_DIR="$SCRIPT_DIR"

# SLURM needs --output to point to an existing directory. We write to a flat
# file in the user dir initially; the job script moves it into job_<ID>/.
JOB_ID=$(sbatch \
    --parsable \
    --job-name="nim-${MODEL_KEY}" \
    --partition=gpu \
    --account=llm-tic \
    --nodes=1 \
    --gres=gpu:4 \
    --time=08:00:00 \
    --output="$NIM_SESSIONS_DIR/$USER/nim-%j.out" \
    --export=ALL \
    "${SBATCH_EXTRA[@]}" \
    "$SCRIPT_DIR/_nim-job.sh" "$MODEL_KEY")

echo "Submitted batch job $JOB_ID"
echo ""
echo "Monitor:"
echo "  tail -F $NIM_SESSIONS_DIR/$USER/job_${JOB_ID}/nim.out"
echo ""
echo "Stop:"
echo "  scancel $JOB_ID"
echo ""
echo "List active NIMs:"
echo "  ./list-nims.sh"
