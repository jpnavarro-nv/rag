#!/bin/bash
# Auto-detect cluster from hostname and export configuration.
#
# Sources the matching clusters/*.conf file, setting LLM_BASE_DIR,
# SLURM_PARTITION, SLURM_ACCOUNT, and other cluster-specific variables.
#
# Detection: matches hostname against known patterns. Falls back to
# CLUSTER_NAME environment variable if hostname is unrecognized.
#
# Usage:
#   source cluster-config.sh            # auto-detect
#   CLUSTER_NAME=lncc source cluster-config.sh   # force cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS_DIR="$SCRIPT_DIR/clusters"

# ==============================================================================
# Auto-detect cluster from hostname
# ==============================================================================
_detect_cluster() {
    local host
    host="$(hostname -f 2>/dev/null || hostname)"

    case "$host" in
        *gaia*.petrobras.com.br|gaiasc*|gaiab*)
            echo "gaia"
            ;;
        *lncc*|*sdumont*|*petrobr*)
            echo "lncc"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ==============================================================================
# Resolve and source cluster config
# ==============================================================================
CLUSTER_NAME="${CLUSTER_NAME:-$(_detect_cluster)}"

if [ -z "$CLUSTER_NAME" ]; then
    echo "ERROR: Cannot detect cluster from hostname '$(hostname)'." >&2
    echo "Set CLUSTER_NAME=<name> manually (available: $(ls "$CLUSTERS_DIR"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf//' | tr '\n' ' '))" >&2
    return 1 2>/dev/null || exit 1
fi

_CONF="$CLUSTERS_DIR/${CLUSTER_NAME}.conf"

if [ ! -f "$_CONF" ]; then
    echo "ERROR: Cluster config not found: $_CONF" >&2
    echo "Available: $(ls "$CLUSTERS_DIR"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf//')" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$_CONF"

# Export all variables from the conf file
export LLM_BASE_DIR SLURM_PARTITION SLURM_ACCOUNT SLURM_GPUS_PER_NODE SLURM_TIME CLUSTER_GPU CLUSTER_NAME

echo "Cluster: $CLUSTER_NAME ($CLUSTER_GPU) — $LLM_BASE_DIR"
