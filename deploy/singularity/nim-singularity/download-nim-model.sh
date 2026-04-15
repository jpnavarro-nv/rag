#!/bin/bash
# Pre-download model weights from HuggingFace via nim-tools.sif.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#   ./download-nim-model.sh nemotron3-120b     # download model weights
#   ./download-nim-model.sh --list             # list available models

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# HuggingFace model mapping (model_key | hf_repo)
# ==============================================================================
HF_MODELS="
nemotron3-120b | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16
gpt-oss-120b   | openai/gpt-oss-120b
qwen3-122b     | Qwen/Qwen3.5-122B-A10B
llama31-70b    | meta-llama/Llama-3.1-70B-Instruct
"

resolve_hf_model() {
    local key="$1"
    while IFS='|' read -r m_key m_repo; do
        m_key=$(echo "$m_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_repo=$(echo "$m_repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$m_key" ] && continue
        if [ "$m_key" = "$key" ]; then
            HF_REPO="$m_repo"
            return 0
        fi
    done <<< "$HF_MODELS"
    return 1
}

list_hf_models() {
    echo "Models with HuggingFace download support:"
    echo ""
    printf "  %-18s %s\n" "KEY" "HUGGINGFACE REPO"
    printf "  %-18s %s\n" "---" "---"
    while IFS='|' read -r m_key m_repo; do
        m_key=$(echo "$m_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_repo=$(echo "$m_repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$m_key" ] && continue
        printf "  %-18s %s\n" "$m_key" "$m_repo"
    done <<< "$HF_MODELS"
    echo ""
}

# ==============================================================================
# Parse arguments
# ==============================================================================
MODEL_KEY=""

for arg in "$@"; do
    case "$arg" in
        --help|-h) echo "Usage: ./download-nim-model.sh [--list|--help] MODEL"; exit 0 ;;
        --list|-l) list_hf_models; exit 0 ;;
        --*)       echo "Unknown option: $arg"; exit 1 ;;
        *)         MODEL_KEY="$arg" ;;
    esac
done

[ -z "$MODEL_KEY" ] && { echo "ERROR: No model specified. Use --list to see models."; exit 1; }
[ -z "$NIM_BASE_DIR" ] && { echo "ERROR: NIM_BASE_DIR is not set."; exit 1; }

resolve_hf_model "$MODEL_KEY" || { echo "ERROR: Unknown model '$MODEL_KEY'."; list_hf_models; exit 1; }

source "$SCRIPT_DIR/nim-config.sh"

TOOLS_SIF="$NIM_IMAGES_DIR/nim-tools.sif"
[ ! -f "$TOOLS_SIF" ] && { echo "ERROR: nim-tools.sif not found. Run ./build-tools-image.sh first."; exit 1; }

DOWNLOAD_DIR="$NIM_MODELS_DIR/${MODEL_KEY}-hf"
mkdir -p "$DOWNLOAD_DIR"

echo "=== Model Download (HuggingFace) ==="
echo "  Model:  $MODEL_KEY"
echo "  Repo:   $HF_REPO"
echo "  Target: $DOWNLOAD_DIR"
echo ""

singularity exec \
    --bind "$NIM_BASE_DIR:$NIM_BASE_DIR" \
    "$TOOLS_SIF" \
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download('$HF_REPO', local_dir='$DOWNLOAD_DIR')"

echo ""
echo "Done: $DOWNLOAD_DIR ($(du -sh "$DOWNLOAD_DIR" | cut -f1))"
echo "Submit: ./submit-nim-job.sh $MODEL_KEY"
