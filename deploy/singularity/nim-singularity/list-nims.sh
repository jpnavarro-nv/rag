#!/bin/bash
# List active NIM LLM jobs across the cluster.
#
# Scans session directories for nim.env metadata files and cross-references
# with SLURM to show only running jobs. Works for all users by default.
#
# Usage:
#   ./list-nims.sh              # show all active NIMs
#   ./list-nims.sh --mine       # show only your NIMs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Source shared paths (needs NIM_BASE_DIR)
# ==============================================================================
export NIM_BASE_DIR="${NIM_BASE_DIR:?NIM_BASE_DIR must be set}"
source "$SCRIPT_DIR/nim-dirs.sh"

# ==============================================================================
# Parse arguments
# ==============================================================================
FILTER_USER=""

for arg in "$@"; do
    case "$arg" in
        --mine|-m)
            FILTER_USER="$USER"
            ;;
        --help|-h)
            echo "Usage: ./list-nims.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --mine, -m    Show only your NIMs (filter by \$USER)"
            echo "  --help, -h    Show this help"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option '$arg'."
            echo "Run './list-nims.sh --help' for usage."
            exit 1
            ;;
    esac
done

# ==============================================================================
# Collect active SLURM job IDs (fast lookup set)
# ==============================================================================
declare -A ACTIVE_JOBS
while read -r jid; do
    ACTIVE_JOBS["$jid"]=1
done < <(squeue --noheader --format="%i" 2>/dev/null)

# ==============================================================================
# Scan session directories for nim.env files
# ==============================================================================
FOUND=0

printf "%-10s %-12s %-18s %-8s %-16s %-6s %s\n" \
    "JOB_ID" "USER" "MODEL" "BACKEND" "NODE" "PORT" "ENDPOINT"
printf "%-10s %-12s %-18s %-8s %-16s %-6s %s\n" \
    "------" "----" "-----" "-------" "----" "----" "--------"

for env_file in "$NIM_SESSIONS_DIR"/*/job_*/nim.env; do
    [ -f "$env_file" ] || continue

    # Extract job ID from path: .../sessions/<user>/job_<id>/nim.env
    job_dir="$(dirname "$env_file")"
    job_id="${job_dir##*job_}"
    session_user="$(basename "$(dirname "$job_dir")")"

    # Skip if job is no longer active in SLURM
    [ -n "${ACTIVE_JOBS[$job_id]+x}" ] || continue

    # Apply user filter
    if [ -n "$FILTER_USER" ] && [ "$session_user" != "$FILTER_USER" ]; then
        continue
    fi

    # Source nim.env for metadata
    local_model="" local_node="" local_port="" local_endpoint="" local_backend=""
    while IFS='=' read -r key value; do
        value="${value%\"}" ; value="${value#\"}"
        case "$key" in
            MODEL_KEY)  local_model="$value" ;;
            BACKEND)    local_backend="$value" ;;
            NODE)       local_node="$value" ;;
            PORT)       local_port="$value" ;;
            ENDPOINT)   local_endpoint="$value" ;;
        esac
    done < "$env_file"

    printf "%-10s %-12s %-18s %-8s %-16s %-6s %s\n" \
        "$job_id" "$session_user" "$local_model" "$local_backend" "$local_node" "$local_port" "$local_endpoint"

    FOUND=$((FOUND + 1))
done

if [ "$FOUND" -eq 0 ]; then
    echo ""
    if [ -n "$FILTER_USER" ]; then
        echo "No active NIMs found for user '$FILTER_USER'."
    else
        echo "No active NIMs found."
    fi
    echo "Submit a job with: ./submit-nim-job.sh <model-key>"
fi
