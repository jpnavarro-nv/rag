#!/bin/bash
# List active LLM jobs across the cluster.
#
# Scans session directories for nim.env metadata files and cross-references
# with SLURM to show only running jobs. Works for all users by default.
#
# Usage:
#   ./list-nims.sh              # show all active LLMs
#   ./list-nims.sh --mine       # show only your LLMs
#   ./list-nims.sh --watch      # auto-refresh every 5s (Ctrl+C to stop)
#   ./list-nims.sh --watch=10   # auto-refresh every 10s

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==============================================================================
# Auto-detect cluster if NIM_BASE_DIR not set
# ==============================================================================
[ -z "$NIM_BASE_DIR" ] && source "$SCRIPT_DIR/cluster-config.sh"
source "$SCRIPT_DIR/nim-dirs.sh"

# ==============================================================================
# Parse arguments
# ==============================================================================
FILTER_USER=""
WATCH_INTERVAL=0

for arg in "$@"; do
    case "$arg" in
        --mine|-m)
            FILTER_USER="$USER"
            ;;
        --watch|-w)
            WATCH_INTERVAL=5
            ;;
        --watch=*)
            WATCH_INTERVAL="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: ./list-nims.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --mine, -m        Show only your LLMs (filter by \$USER)"
            echo "  --watch, -w       Auto-refresh every 5s (Ctrl+C to stop)"
            echo "  --watch=N         Auto-refresh every N seconds"
            echo "  --help, -h        Show this help"
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
# Main listing logic (called once or in a loop)
# ==============================================================================
list_nims() {
    # Collect active SLURM job IDs (fast lookup set)
    declare -A ACTIVE_JOBS
    while read -r jid; do
        ACTIVE_JOBS["$jid"]=1
    done < <(squeue --noheader --format="%i" 2>/dev/null)

    # Print header
    local FOUND=0

    printf "%-10s %-12s %-18s %-8s %-16s %-6s %-8s %s\n" \
        "JOB_ID" "USER" "MODEL" "BACKEND" "NODE" "PORT" "STATUS" "ENDPOINT"
    printf "%-10s %-12s %-18s %-8s %-16s %-6s %-8s %s\n" \
        "------" "----" "-----" "-------" "----" "----" "------" "--------"

    # Scan session directories for nim.env files
    for env_file in "$NIM_SESSIONS_DIR"/*/job_*/nim.env; do
        [ -f "$env_file" ] || continue

        # Extract job ID from path: .../sessions/<user>/job_<id>/nim.env
        local job_dir job_id session_user
        job_dir="$(dirname "$env_file")"
        job_id="${job_dir##*job_}"
        session_user="$(basename "$(dirname "$job_dir")")"

        # Skip if job is no longer active in SLURM
        [ -n "${ACTIVE_JOBS[$job_id]+x}" ] || continue

        # Apply user filter
        if [ -n "$FILTER_USER" ] && [ "$session_user" != "$FILTER_USER" ]; then
            continue
        fi

        # Parse nim.env for metadata
        local local_model="" local_node="" local_port="" local_endpoint="" local_backend=""
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

        # Health check (2s timeout, silent)
        local local_status="loading" http_code=""
        if [ -n "$local_endpoint" ]; then
            http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$local_endpoint/health" 2>/dev/null) || http_code=""
            if [ "$http_code" = "200" ]; then
                local_status="ready"
            elif [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
                local_status="err:$http_code"
            fi
        fi

        printf "%-10s %-12s %-18s %-8s %-16s %-6s %-8s %s\n" \
            "$job_id" "$session_user" "$local_model" "$local_backend" "$local_node" "$local_port" "$local_status" "$local_endpoint"

        FOUND=$((FOUND + 1))
    done

    if [ "$FOUND" -eq 0 ]; then
        echo ""
        if [ -n "$FILTER_USER" ]; then
            echo "No active LLMs found for user '$FILTER_USER'."
        else
            echo "No active LLMs found."
        fi
        echo "Submit a job with: ./submit-nim-job.sh <model-key>"
    fi
}

# ==============================================================================
# Run once or in watch mode
# ==============================================================================
if [ "$WATCH_INTERVAL" -gt 0 ] 2>/dev/null; then
    trap 'printf "\n"; exit 0' INT
    while true; do
        clear
        echo "=== LLM Status (every ${WATCH_INTERVAL}s — Ctrl+C to stop) ==="
        echo ""
        list_nims
        sleep "$WATCH_INTERVAL"
    done
else
    list_nims
fi
