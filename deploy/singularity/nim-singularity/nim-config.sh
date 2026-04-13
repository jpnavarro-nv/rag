#!/bin/bash
# Configuration and model catalog for NIM Singularity deployment.
#
# Sources nim-dirs.sh for shared paths and provides:
#   - resolve_model()   Lookup a model key in models.conf
#   - list_models()     Print formatted table of available models
#   - all_model_keys()  Return all model keys from models.conf
#
# Required environment variables (set before sourcing):
#   NGC_API_KEY    — NVIDIA NGC API key for NIM containers
#   NIM_BASE_DIR   — Base directory for all NIM data

# ==============================================================================
# Shared paths (from nim-dirs.sh)
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/nim-dirs.sh"

# ==============================================================================
# Singularity configuration
# ==============================================================================
# SINGULARITY_TMPDIR must point to a local POSIX filesystem (not Lustre/NFS).
# Singularity uses it for the --nv driver-libs bundle and namespace structures
# that require overlayfs/hard-link support unavailable on Lustre.
export SINGULARITY_TMPDIR=/tmp

# ==============================================================================
# NGC authentication
# ==============================================================================
export NGC_API_KEY="${NGC_API_KEY:?NGC_API_KEY must be set}"

# ==============================================================================
# Defaults (overridable via environment)
# ==============================================================================
export LLM_PORT=${LLM_PORT:-8000}
export CHECK_INTERVAL=${CHECK_INTERVAL:-15}

# ==============================================================================
# Model catalog path
# ==============================================================================
_NIM_MODELS_CONF="$(dirname "${BASH_SOURCE[0]}")/models.conf"

# ==============================================================================
# resolve_model() — Lookup a model key in models.conf
#
# Sets global variables: MODEL_KEY, DOCKER_URI, SIF_NAME, MODEL_DESC,
#                        MODEL_EXTRA_ENV, MODEL_BACKEND, MODEL_ID
# Returns 0 on success, 1 if the key is not found.
# ==============================================================================
resolve_model() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "ERROR: resolve_model() requires a model key argument." >&2
        return 1
    fi
    while IFS='|' read -r m_key m_uri m_sif m_desc m_extra m_backend; do
        # Trim leading/trailing whitespace
        m_key=$(echo "$m_key" | xargs)
        m_uri=$(echo "$m_uri" | xargs)
        m_sif=$(echo "$m_sif" | xargs)
        m_desc=$(echo "$m_desc" | xargs)
        m_extra=$(echo "$m_extra" | xargs)
        m_backend=$(echo "$m_backend" | xargs)
        if [ "$m_key" = "$key" ]; then
            MODEL_KEY="$m_key"
            DOCKER_URI="$m_uri"
            SIF_NAME="$m_sif"
            MODEL_DESC="$m_desc"
            MODEL_EXTRA_ENV="$m_extra"
            MODEL_BACKEND="${m_backend:-nim}"
            # Extract model ID from the image URI or vLLM args
            if [ "$MODEL_BACKEND" = "vllm" ]; then
                # For vLLM: use --served-model-name from extra_args
                MODEL_ID=$(echo "$MODEL_EXTRA_ENV" | sed -n 's/.*--served-model-name[[:space:]]*\([^[:space:]]*\).*/\1/p')
                [ -z "$MODEL_ID" ] && MODEL_ID="$MODEL_KEY"
            else
                # For NIM: strip tag and registry prefix
                # e.g. nvcr.io/nim/nvidia/model:1.0 → nvidia/model
                local no_tag="${DOCKER_URI%%:*}"
                MODEL_ID="${no_tag#*/nim/}"
            fi
            return 0
        fi
    done < <(grep -v '^\s*#' "$_NIM_MODELS_CONF" | grep -v '^\s*$')
    echo "ERROR: Unknown model '$key'." >&2
    echo "Run with --list to see available models." >&2
    return 1
}

# ==============================================================================
# list_models() — Print formatted table of available models
# ==============================================================================
list_models() {
    echo "Available models (from models.conf):"
    echo ""
    printf "  %-18s %s\n" "KEY" "DESCRIPTION"
    printf "  %-18s %s\n" "---" "-----------"
    while IFS='|' read -r m_key _ _ m_desc _; do
        m_key=$(echo "$m_key" | xargs)
        m_desc=$(echo "$m_desc" | xargs)
        printf "  %-18s %s\n" "$m_key" "$m_desc"
    done < <(grep -v '^\s*#' "$_NIM_MODELS_CONF" | grep -v '^\s*$')
    echo ""
}

# ==============================================================================
# all_model_keys() — Return all model keys from models.conf (one per line)
# ==============================================================================
all_model_keys() {
    while IFS='|' read -r m_key _ _ _ _; do
        echo "$m_key" | xargs
    done < <(grep -v '^\s*#' "$_NIM_MODELS_CONF" | grep -v '^\s*$')
}
