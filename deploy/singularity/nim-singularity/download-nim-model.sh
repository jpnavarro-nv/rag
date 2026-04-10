#!/bin/bash
# Pre-download NIM model weights from HuggingFace via nim-tools.sif.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./download-nim-model.sh nemotron3-120b              # download FP8 (default)
#   ./download-nim-model.sh nemotron3-120b --bf16       # download BF16 variant
#   ./download-nim-model.sh --list                      # list available models

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# HuggingFace model mapping (model_key | fp8_repo | bf16_repo)
# ==============================================================================
HF_MODELS="
nemotron3-120b | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-FP8 | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16
"

resolve_hf_model() {
    local key="$1" precision="$2"
    while IFS='|' read -r m_key m_fp8 m_bf16; do
        m_key=$(echo "$m_key" | xargs)
        m_fp8=$(echo "$m_fp8" | xargs)
        m_bf16=$(echo "$m_bf16" | xargs)
        [ -z "$m_key" ] && continue
        if [ "$m_key" = "$key" ]; then
            [ "$precision" = "bf16" ] && HF_REPO="$m_bf16" || HF_REPO="$m_fp8"
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
        m_key=$(echo "$m_key" | xargs); m_fp8=$(echo "$m_fp8" | xargs); m_bf16=$(echo "$m_bf16" | xargs)
        [ -z "$m_key" ] && continue
        printf "  %-18s %-50s %s\n" "$m_key" "$m_fp8" "$m_bf16"
    done <<< "$HF_MODELS"
    echo ""
}

# ==============================================================================
# Parse arguments
# ==============================================================================
MODEL_KEY=""
PRECISION="fp8"

for arg in "$@"; do
    case "$arg" in
        --help|-h) echo "Usage: ./download-nim-model.sh [--bf16|--list|--help] MODEL"; exit 0 ;;
        --list|-l) list_hf_models; exit 0 ;;
        --bf16)    PRECISION="bf16" ;;
        --fp8)     PRECISION="fp8" ;;
        --*)       echo "Unknown option: $arg"; exit 1 ;;
        *)         MODEL_KEY="$arg" ;;
    esac
done

[ -z "$MODEL_KEY" ] && { echo "ERROR: No model specified. Use --list to see models."; exit 1; }
[ -z "$NIM_BASE_DIR" ] && { echo "ERROR: NIM_BASE_DIR is not set."; exit 1; }

resolve_hf_model "$MODEL_KEY" "$PRECISION" || { list_hf_models; exit 1; }

export NGC_API_KEY="${NGC_API_KEY:-placeholder}"
source "$SCRIPT_DIR/nim-config.sh"

TOOLS_SIF="$NIM_IMAGES_DIR/nim-tools.sif"
[ ! -f "$TOOLS_SIF" ] && { echo "ERROR: nim-tools.sif not found. Run ./build-tools-image.sh first."; exit 1; }

DOWNLOAD_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
mkdir -p "$DOWNLOAD_DIR"

echo "=== NIM Model Download (HuggingFace) ==="
echo "  Model:  $MODEL_KEY ($PRECISION)"
echo "  Repo:   $HF_REPO"
echo "  Target: $DOWNLOAD_DIR"
echo ""

singularity exec \
    --bind "$NIM_BASE_DIR:$NIM_BASE_DIR" \
    "$TOOLS_SIF" \
    huggingface-cli download "$HF_REPO" --local-dir "$DOWNLOAD_DIR"

echo ""
echo "Done: $DOWNLOAD_DIR ($(du -sh "$DOWNLOAD_DIR" | cut -f1))"
echo "Submit: ./submit-nim-job.sh $MODEL_KEY"
