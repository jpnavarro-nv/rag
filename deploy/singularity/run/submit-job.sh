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
# Submit with:
#   export NGC_API_KEY="nvapi-..."
#   export RAG_BASE_DIR="/path/to/rag-workdir"
#   sbatch --export=ALL,NGC_API_KEY=$NGC_API_KEY,RAG_BASE_DIR=$RAG_BASE_DIR \
#          submit-job.sh
#
# Optional overrides at submission time:
#   --output=/custom/path/slurm-%j.log
#   --time=10:00:00
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================"
echo "  RAG Blueprint — Slurm Setup Job"
echo "======================================================"
echo "  Job ID   : ${SLURM_JOB_ID}"
echo "  Node     : ${SLURMD_NODENAME}"
echo "  GPUs     : ${SLURM_GPUS_ON_NODE:-${CUDA_VISIBLE_DEVICES}}"
echo "  Base dir : ${RAG_BASE_DIR}"
echo "  Started  : $(date)"
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

echo ""
echo "======================================================"
echo "  RAG Blueprint — Setup complete"
echo "  Finished : $(date)"
echo "======================================================"
