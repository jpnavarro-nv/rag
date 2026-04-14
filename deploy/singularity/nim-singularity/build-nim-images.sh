#!/bin/bash
# Pull vLLM container images from Docker Hub as Singularity SIF files.
#
# Images are stored in $NIM_BASE_DIR/containers/images/ and shared across all
# users and jobs. Already-existing SIFs are skipped unless --force is used.
#
# Usage:
#   export NIM_BASE_DIR="/path/to/shared/dir"
#
#   ./build-nim-images.sh --list                   # show available models
#   ./build-nim-images.sh nemotron3-120b           # pull one model
#   ./build-nim-images.sh --all                    # pull all models
#   ./build-nim-images.sh --force gpt-oss-120b     # re-pull even if exists

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Usage
# ==============================================================================
show_usage() {
    echo "Usage: ./build-nim-images.sh [OPTIONS] MODEL [MODEL...]"
    echo ""
    echo "Options:"
    echo "  --all     Pull all available models"
    echo "  --list    List available models (from models.conf)"
    echo "  --force   Re-pull even if SIF already exists"
    echo "  --help    Show this help"
    echo ""
    echo "Run './build-nim-images.sh --list' to see available models."
}

# ==============================================================================
# Parse arguments
# ==============================================================================
FORCE=false
MODELS=()

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --list|-l)
            # Source nim-config for list_models (needs NIM_BASE_DIR)
            # For --list we only need the catalog, so provide safe defaults
            export NIM_BASE_DIR="${NIM_BASE_DIR:-/tmp}"
            source "$SCRIPT_DIR/nim-config.sh"
            list_models
            exit 0
            ;;
        --force)
            FORCE=true
            ;;
        --all)
            # Resolved after sourcing nim-config.sh
            MODELS=("__ALL__")
            ;;
        --*)
            echo "ERROR: Unknown option '$arg'."
            echo ""
            show_usage
            exit 1
            ;;
        *)
            MODELS+=("$arg")
            ;;
    esac
done

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "ERROR: No model specified."
    echo ""
    show_usage
    exit 1
fi

# ==============================================================================
# Source configuration (validates NIM_BASE_DIR)
# ==============================================================================
source "$SCRIPT_DIR/nim-config.sh"

# Resolve --all to actual model keys
if [ "${MODELS[0]}" = "__ALL__" ]; then
    mapfile -t MODELS < <(all_model_keys)
fi

# ==============================================================================
# Create shared directories
# ==============================================================================
mkdir -p "$NIM_IMAGES_DIR"
mkdir -p "$NIM_CACHE_DIR"

echo "=== vLLM Image Pull ==="
echo ""
echo "NIM_BASE_DIR:  $NIM_BASE_DIR"
echo "Images dir:    $NIM_IMAGES_DIR"
echo "Force re-pull: $FORCE"
echo ""

# ==============================================================================
# Pull requested models
# ==============================================================================
PULLED=0
SKIPPED=0
FAILED=0

for model_key in "${MODELS[@]}"; do
    if ! resolve_model "$model_key"; then
        FAILED=$((FAILED + 1))
        continue
    fi

    echo "[$SIF_NAME] $MODEL_DESC"

    if [ -f "$NIM_IMAGES_DIR/$SIF_NAME" ] && [ "$FORCE" = false ]; then
        echo "  Already exists — skipped (use --force to re-pull)"
        ls -lh "$NIM_IMAGES_DIR/$SIF_NAME" | awk '{print "  Size:", $5}'
        SKIPPED=$((SKIPPED + 1))
    else
        if [ -f "$NIM_IMAGES_DIR/$SIF_NAME" ] && [ "$FORCE" = true ]; then
            echo "  Removing existing SIF (--force)..."
            rm -f "$NIM_IMAGES_DIR/$SIF_NAME"
        fi
        # Set NGC auth for nvcr.io images if NGC_API_KEY is available
        if [[ "$DOCKER_URI" == nvcr.io/* ]] && [ -n "${NGC_API_KEY:-}" ]; then
            export SINGULARITY_DOCKER_USERNAME='$oauthtoken'
            export SINGULARITY_DOCKER_PASSWORD="$NGC_API_KEY"
        else
            unset SINGULARITY_DOCKER_USERNAME SINGULARITY_DOCKER_PASSWORD
        fi
        echo "  Pulling from $DOCKER_URI..."
        if singularity pull "$NIM_IMAGES_DIR/$SIF_NAME" "docker://$DOCKER_URI"; then
            echo "  Pulled successfully"
            ls -lh "$NIM_IMAGES_DIR/$SIF_NAME" | awk '{print "  Size:", $5}'
            PULLED=$((PULLED + 1))
        else
            echo "  Pull FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi
    echo ""
done

# ==============================================================================
# Summary
# ==============================================================================
echo "=== Summary ==="
echo "Pulled:  $PULLED"
echo "Skipped: $SKIPPED"
echo "Failed:  $FAILED"
echo ""

if [ $FAILED -gt 0 ]; then
    echo "Some images failed. Check errors above."
    exit 1
fi

echo "Images ready at: $NIM_IMAGES_DIR"
echo ""
echo "Next step: ./submit-nim-job.sh <model-key>"
