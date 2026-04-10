#!/bin/bash
# Pre-download NIM model weights from HuggingFace.
#
# The NIM internal downloader (NGC) can fail on HPC networks with large models.
# This script downloads weights externally using huggingface-cli (via nim-tools.sif),
# which has robust retry/resume support. Once downloaded, submit-nim-job.sh will
# automatically detect and use the local weights.
#
# Prerequisites:
#   ./build-tools-image.sh    (pulls nim-tools.sif from GHCR)
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#
#   ./download-nim-model.sh nemotron3-120b              # download default (FP8)
#   ./download-nim-model.sh nemotron3-120b --bf16       # download BF16 variant
#   ./download-nim-model.sh --list                      # list available models

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# HuggingFace model mapping
#
# Maps model_key to HuggingFace repo names.
# Format: model_key|hf_repo_fp8|hf_repo_bf16
# ==============================================================================
HF_MODELS="
nemotron3-120b | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8 | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16
"

resolve_hf_model() {
    local key="$1"
    local precision="$2"
    while IFS='|' read -r m_key m_fp8 m_bf16; do
        m_key=$(echo "$m_key" | xargs)
        m_fp8=$(echo "$m_fp8" | xargs)
        m_bf16=$(echo "$m_bf16" | xargs)
        [ -z "$m_key" ] && continue
        if [ "$m_key" = "$key" ]; then
            if [ "$precision" = "bf16" ]; then
                HF_REPO="$m_bf16"
            else
                HF_REPO="$m_fp8"
            fi
            return 0
        fi
    done <<< "$HF_MODELS"
    return 1
}

list_hf_models() {
    echo "Models with HuggingFace download support:"
    echo ""
    printf "  %-18s %-50s %s\n" "KEY" "FP8 (default)" "BF16"
    printf "  %-18s %-50s %s\n" "---" "---" "---"
    while IFS='|' read -r m_key m_fp8 m_bf16; do
        m_key=$(echo "$m_key" | xargs)
        m_fp8=$(echo "$m_fp8" | xargs)
        m_bf16=$(echo "$m_bf16" | xargs)
        [ -z "$m_key" ] && continue
        printf "  %-18s %-50s %s\n" "$m_key" "$m_fp8" "$m_bf16"
    done <<< "$HF_MODELS"
    echo ""
}

# ==============================================================================
# Usage
# ==============================================================================
show_usage() {
    echo "Usage: ./download-nim-model.sh [OPTIONS] MODEL"
    echo ""
    echo "Pre-download NIM model weights from HuggingFace (via nim-tools.sif)."
    echo "Downloads are resumable — re-run to continue interrupted downloads."
    echo ""
    echo "Options:"
    echo "  --bf16    Download BF16 variant (larger, full precision)"
    echo "  --list    List models with HuggingFace download support"
    echo "  --help    Show this help"
    echo ""
    echo "Default precision is FP8 (smaller download, fits 4x A100 80GB)."
    echo ""
    echo "Prerequisite: ./build-tools-image.sh"
}

# ==============================================================================
# Parse arguments
# ==============================================================================
MODEL_KEY=""
PRECISION="fp8"

for arg in "$@"; do
    case "$arg" in
        --help|-h) show_usage; exit 0 ;;
        --list|-l) list_hf_models; exit 0 ;;
        --bf16)    PRECISION="bf16" ;;
        --fp8)     PRECISION="fp8" ;;
        --*)       echo "Unknown option: $arg"; exit 1 ;;
        *)         MODEL_KEY="$arg" ;;
    esac
done

if [ -z "$MODEL_KEY" ]; then
    echo "ERROR: No model specified."
    echo ""
    show_usage
    exit 1
fi

# ==============================================================================
# Validate
# ==============================================================================
if [ -z "$NIM_BASE_DIR" ]; then
    echo "ERROR: NIM_BASE_DIR is not set."
    echo ""
    echo "Set it to the shared directory for NIM data:"
    echo "  export NIM_BASE_DIR=\"/path/to/shared/dir\""
    exit 1
fi

if ! resolve_hf_model "$MODEL_KEY" "$PRECISION"; then
    echo "ERROR: No HuggingFace mapping for model '$MODEL_KEY'."
    echo ""
    list_hf_models
    exit 1
fi

# ==============================================================================
# Source paths
# ==============================================================================
# Only need NIM_BASE_DIR for paths — NGC_API_KEY not required for HF download
export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

TOOLS_SIF="$NIM_IMAGES_DIR/nim-tools.sif"
if [ ! -f "$TOOLS_SIF" ]; then
    echo "ERROR: nim-tools.sif not found: $TOOLS_SIF"
    echo ""
    echo "Build it first:"
    echo "  ./build-tools-image.sh"
    exit 1
fi

DOWNLOAD_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
mkdir -p "$DOWNLOAD_DIR"

echo "=== NIM Model Download (HuggingFace) ==="
echo ""
echo "Model:     $MODEL_KEY ($PRECISION)"
echo "HF Repo:   $HF_REPO"
echo "Target:    $DOWNLOAD_DIR"
echo "Container: $TOOLS_SIF"
echo ""
echo "Download is resumable. Re-run this script if interrupted."
echo ""

# ==============================================================================
# Download via nim-tools.sif
# ==============================================================================
singularity exec \
    --bind "$NIM_BASE_DIR:$NIM_BASE_DIR" \
    "$TOOLS_SIF" \
    huggingface-cli download "$HF_REPO" \
        --local-dir "$DOWNLOAD_DIR"

echo ""
echo "============================================================"
echo "Download complete: $MODEL_KEY ($PRECISION)"
echo "Location: $DOWNLOAD_DIR ($(du -sh "$DOWNLOAD_DIR" | cut -f1))"
echo "============================================================"
echo ""
echo "Submit the job normally — local weights will be used automatically:"
echo "  ./submit-nim-job.sh $MODEL_KEY"
