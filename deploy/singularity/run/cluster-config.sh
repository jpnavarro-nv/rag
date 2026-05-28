#!/bin/bash
# Auto-detect the current cluster from $(hostname -f) and source the matching
# clusters/<name>.conf so Slurm-specific values (RAG_BASE_DIR, partition,
# account, GPUs-per-node, walltime) come from data, not hard-coded directives.
#
# Usage:
#   source cluster-config.sh                # auto-detect from hostname
#   CLUSTER_NAME=lncc source cluster-config.sh   # force a specific cluster
#
# Exports (from the resolved <name>.conf):
#   CLUSTER_NAME, CLUSTER_GPU
#   RAG_BASE_DIR (only if not already set in the calling shell)
#   SLURM_PARTITION, SLURM_ACCOUNT, SLURM_GPUS_PER_NODE
#   SLURM_TIME      (may be empty — wrapper skips --time when empty,
#                    leaving the partition's default/max in effect)
#
# Validation: this script verifies that the required fields are non-empty so
# typos in a *.conf surface here, not as a confusing sbatch CLI rejection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS_DIR="$SCRIPT_DIR/clusters"

# ==============================================================================
# Auto-detect cluster from hostname
# ==============================================================================
_detect_cluster() {
    # hostname -f preferred (FQDN match like *.petrobras.com.br); fall back to
    # plain hostname on clusters without reverse DNS / search domain.
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
# Resolve cluster name
# ==============================================================================
CLUSTER_NAME="${CLUSTER_NAME:-$(_detect_cluster)}"

_AVAILABLE() {
    ls "$CLUSTERS_DIR"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf//' | tr '\n' ' '
}

if [ -z "$CLUSTER_NAME" ]; then
    echo "ERROR: Cannot detect cluster from hostname '$(hostname -f 2>/dev/null || hostname)'." >&2
    echo "Set CLUSTER_NAME=<name> manually (available: $(_AVAILABLE))" >&2
    return 1 2>/dev/null || exit 1
fi

_CONF="$CLUSTERS_DIR/${CLUSTER_NAME}.conf"
if [ ! -f "$_CONF" ]; then
    echo "ERROR: Cluster config not found: $_CONF" >&2
    echo "Available: $(_AVAILABLE)" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$_CONF"

# ==============================================================================
# Validate required fields (SLURM_TIME is optional — empty means "no limit")
# ==============================================================================
for _field in RAG_BASE_DIR SLURM_PARTITION SLURM_ACCOUNT SLURM_GPUS_PER_NODE CLUSTER_GPU; do
    if [ -z "${!_field:-}" ]; then
        echo "ERROR: $_field is empty after sourcing $_CONF" >&2
        echo "Check the cluster conf for typos or missing assignments." >&2
        return 1 2>/dev/null || exit 1
    fi
done

# Export so the wrapper sees them after sourcing this script.
export CLUSTER_NAME CLUSTER_GPU
export RAG_BASE_DIR
export SLURM_PARTITION SLURM_ACCOUNT SLURM_GPUS_PER_NODE SLURM_TIME

echo "Cluster: $CLUSTER_NAME ($CLUSTER_GPU) — $RAG_BASE_DIR"
