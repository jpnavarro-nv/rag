#!/bin/bash
# Configuration and model catalog for LLM Singularity deployment (vLLM).
#
# Sources llm-dirs.sh for shared paths and provides:
#   - resolve_model()   Lookup a model key in models.conf
#   - list_models()     Print formatted table of available models
#   - all_model_keys()  Return all model keys from models.conf
#
# Required environment variables (set before sourcing):
#   LLM_BASE_DIR   — Base directory for all deployment data

# ==============================================================================
# Shared paths (from llm-dirs.sh)
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/llm-dirs.sh"

# ==============================================================================
# Singularity configuration
# ==============================================================================
# SINGULARITY_TMPDIR must point to a local POSIX filesystem (not Lustre/NFS).
# Singularity uses it for the --nv driver-libs bundle and namespace structures
# that require overlayfs/hard-link support unavailable on Lustre.
export SINGULARITY_TMPDIR=/tmp

# ==============================================================================
# Defaults (overridable via environment)
# ==============================================================================
export LLM_PORT=${LLM_PORT:-8000}
export CHECK_INTERVAL=${CHECK_INTERVAL:-15}

# ==============================================================================
# Model catalog path
# ==============================================================================
_LLM_MODELS_CONF="$(dirname "${BASH_SOURCE[0]}")/models.conf"

# ==============================================================================
# resolve_model() — Lookup a model key in models.conf
#
# Sets global variables: MODEL_KEY, DOCKER_URI, SIF_NAME, MODEL_DESC,
#                        MODEL_EXTRA_ENV, MODEL_ID
# Returns 0 on success, 1 if the key is not found.
# ==============================================================================
resolve_model() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "ERROR: resolve_model() requires a model key argument." >&2
        return 1
    fi
    while IFS='|' read -r m_key m_uri m_sif m_desc m_extra; do
        # Trim whitespace with sed (not xargs — xargs strips shell quotes)
        m_key=$(echo "$m_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_uri=$(echo "$m_uri" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_sif=$(echo "$m_sif" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_desc=$(echo "$m_desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_extra=$(echo "$m_extra" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ "$m_key" = "$key" ]; then
            MODEL_KEY="$m_key"
            DOCKER_URI="$m_uri"
            SIF_NAME="$m_sif"
            MODEL_DESC="$m_desc"
            MODEL_EXTRA_ENV="$m_extra"
            # Extract model ID from --served-model-name in extra_args
            MODEL_ID=$(echo "$MODEL_EXTRA_ENV" | sed -n 's/.*--served-model-name[[:space:]]*\([^[:space:]]*\).*/\1/p')
            [ -z "$MODEL_ID" ] && MODEL_ID="$MODEL_KEY"
            return 0
        fi
    done < <(grep -v '^\s*#' "$_LLM_MODELS_CONF" | grep -v '^\s*$')
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
        m_key=$(echo "$m_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        m_desc=$(echo "$m_desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        printf "  %-18s %s\n" "$m_key" "$m_desc"
    done < <(grep -v '^\s*#' "$_LLM_MODELS_CONF" | grep -v '^\s*$')
    echo ""
}

# ==============================================================================
# all_model_keys() — Return all model keys from models.conf (one per line)
# ==============================================================================
all_model_keys() {
    while IFS='|' read -r m_key _ _ _ _; do
        echo "$m_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    done < <(grep -v '^\s*#' "$_LLM_MODELS_CONF" | grep -v '^\s*$')
}
