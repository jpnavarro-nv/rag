#!/bin/bash
# ==============================================================================
# diag-ingestor.sh — standalone readiness diagnostics for the Ingestor (8082).
#
# WHY: 06-start-ingest-server.sh intermittently fails in wait_for_ingestor with
#   "Ingestor Server failed to become ready after Ns". The code is unchanged
#   since Feb/2026 — the failure is node/run-dependent. When 06 exits 1, the
#   deploy aborts (set -e) and Slurm cgroup teardown kills the backgrounded
#   uvicorn, so evidence MUST be captured CONCURRENTLY, during the deploy window.
#
# This script does NOT modify 01-09. Run it on the SAME compute node as the
# deploy (via `srun --overlap --jobid=$JID -w $NODE bash <this>`), ideally
# launched a bit before step [6/9]. It polls 8082 and records the decisive
# signals, then writes a git-trackable report under import_logs/debug-06c/.
#
# It captures (per the validation review):
#   - ss listener + ADDRESS FAMILY (0.0.0.0 vs [::] vs 127.0.0.1)  <-- IPv6 q.
#   - dual curl: http://localhost vs http://127.0.0.1, with exit code via $?
#       (7=conn refused, 28=timeout, 6=DNS, 0=ok)
#   - first-LISTEN and first-200 elapsed times (window-start wallclock anchored)
#   - ingestor-server.log mtime + the "Uvicorn running" line (the log has NO
#     timestamps, so we anchor bind-time against the collector's own clock)
#   - node identity for cross-failure correlation
#
# The report is written as *.out/*.log so it is NOT gitignored. It does NOT
# commit/push (compute-node outbound may be blocked) — commit from the login
# node afterwards.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults ---------------------------------------------------------------
PORT=8082
OUT_DIR="$SCRIPT_DIR/import_logs/debug-06c"
LOGS_DIR=""                       # ingestor logs dir (has ingestor-server.log)
DURATION=2400                     # max seconds to watch (covers 04-wait + 06)
INTERVAL=3                        # seconds between samples
STABLE_AFTER=15                   # stop this many s after first stable 200

usage() {
    cat <<EOF
Usage: $0 [--port N] [--logs DIR] [--out DIR] [--duration S] [--interval S]
  --logs DIR   Ingestor logs dir (the "Logs: ..." path from the deploy banner).
               Used to copy ingestor-server.log + its mtime. Optional but
               strongly recommended (anchors bind-time vs the readiness window).
  --out  DIR   Where to write the report (default: $OUT_DIR)
  --port N     Ingestor port (default: 8082)
  --duration S Max watch seconds (default: 2400 = 40min)
  --interval S Sample interval (default: 3)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2;;
        --logs) LOGS_DIR="$2"; shift 2;;
        --out)  OUT_DIR="$2"; shift 2;;
        --duration) DURATION="$2"; shift 2;;
        --interval) INTERVAL="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown arg: $1" >&2; usage; exit 2;;
    esac
done

NODE="${SLURMD_NODENAME:-$(hostname)}"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/ingestor-diag-${NODE}-${SLURM_JOB_ID:-nojob}.out"

# port in hex for /proc/net/tcp{,6} (8082 -> 1F92), uppercase, zero-padded
PORT_HEX=$(printf '%04X' "$PORT")

# ---- helper: one curl probe, returns "rc=.. code=.. ip=.. t=.." -------------
probe() {
    local url="$1" out rc
    out=$(curl -sS -o /dev/null \
        -w 'code=%{http_code} ip=%{remote_ip} t=%{time_total}' \
        --max-time 5 "$url" 2>/dev/null)
    rc=$?
    echo "rc=$rc $out"
}

# ---- header (one-shot environment facts) ------------------------------------
{
    echo "=============================================================="
    echo " INGESTOR READINESS DIAGNOSTIC"
    echo "=============================================================="
    echo "node            : $NODE"
    echo "slurm_job_id    : ${SLURM_JOB_ID:-<none>}"
    echo "port            : $PORT (hex $PORT_HEX)"
    echo "start_wallclock : $(date -Iseconds)"
    echo "kernel          : $(uname -r)"
    echo "curl_version    : $(curl --version 2>/dev/null | head -1)"
    echo
    echo "-- name resolution (crux of the IPv6 theory) --"
    echo "getent hosts localhost     : $(getent hosts localhost 2>/dev/null | tr '\n' ';')"
    echo "getent hosts ip6-localhost : $(getent hosts ip6-localhost 2>/dev/null | tr '\n' ';')"
    echo "/etc/hosts loopback lines  :"
    grep -E '127\.0\.0\.1|::1|localhost' /etc/hosts 2>/dev/null | sed 's/^/    /'
    echo
    echo "logs_dir        : ${LOGS_DIR:-<not provided>}"
    echo "=============================================================="
    echo
    echo "TIMELINE (elapsed | ss listeners on :$PORT | curl localhost | curl 127.0.0.1)"
} > "$REPORT"

# ---- watch loop -------------------------------------------------------------
first_listen=""; first_listen_fam=""; first_200=""; uvicorn_logged=""
t0=$(date +%s)

while :; do
    now=$(date +%s); el=$((now - t0))
    [ "$el" -ge "$DURATION" ] && break
    ts=$(date -Iseconds)

    # listeners (full lines show the bind address: 0.0.0.0 / [::] / 127.0.0.1)
    ss_lines=$(ss -Hltn "sport = :$PORT" 2>/dev/null)
    listen_n=$(printf '%s\n' "$ss_lines" | grep -c ":$PORT" || true)
    # collapse listener bind addrs onto one line for the timeline
    ss_addrs=$(printf '%s\n' "$ss_lines" | awk '{print $4}' | paste -sd, - 2>/dev/null)

    cl=$(probe "http://localhost:$PORT/health")
    c4=$(probe "http://127.0.0.1:$PORT/health")

    printf '[%s] el=%4ss listen=%s addrs=[%s] | localhost: %s | 127.0.0.1: %s\n' \
        "$ts" "$el" "$listen_n" "${ss_addrs:-}" "$cl" "$c4" >> "$REPORT"

    # first listener seen — record elapsed + bind family
    if [ "${listen_n:-0}" -gt 0 ] && [ -z "$first_listen" ]; then
        first_listen=$el; first_listen_fam="${ss_addrs:-?}"
        echo "    >>> first LISTEN at ${el}s on [${first_listen_fam}]" >> "$REPORT"
    fi
    # first HTTP 200 on either probe
    if printf '%s %s' "$cl" "$c4" | grep -q 'code=200' && [ -z "$first_200" ]; then
        first_200=$el
        echo "    >>> first HTTP 200 at ${el}s" >> "$REPORT"
    fi
    # anchor the timestampless app log: note when "Uvicorn running" appears
    if [ -n "$LOGS_DIR" ] && [ -f "$LOGS_DIR/ingestor-server.log" ] && [ -z "$uvicorn_logged" ]; then
        if grep -q 'Uvicorn running' "$LOGS_DIR/ingestor-server.log" 2>/dev/null; then
            uvicorn_logged=$el
            echo "    >>> 'Uvicorn running' present in log at observed ${el}s (log mtime $(stat -c %y "$LOGS_DIR/ingestor-server.log" 2>/dev/null))" >> "$REPORT"
        fi
    fi

    # stop once stably ready
    if [ -n "$first_200" ] && [ "$el" -ge $((first_200 + STABLE_AFTER)) ]; then break; fi
    sleep "$INTERVAL"
done

# ---- final snapshots (also runs on Ctrl-C so the report is always complete) -
_finalized=""
finalize() {
    [ -n "$_finalized" ] && return; _finalized=1
{
    echo
    echo "=== final ss (-ltnp) on :$PORT ==="
    ss -ltnp "sport = :$PORT" 2>/dev/null
    echo
    echo "=== /proc/net/tcp  (port $PORT_HEX) ==="
    grep -i ":$PORT_HEX " /proc/net/tcp 2>/dev/null | sed 's/^/    /'
    echo "=== /proc/net/tcp6 (port $PORT_HEX) ==="
    grep -i ":$PORT_HEX " /proc/net/tcp6 2>/dev/null | sed 's/^/    /'
    echo
    echo "=== ps (uvicorn / singularity / apptainer / starter) ==="
    ps -eo pid,ppid,etimes,rss,cmd 2>/dev/null | grep -E 'uvicorn|singularity|apptainer|starter' | grep -v grep
    echo
    echo "=== SUMMARY ==="
    echo "node               : $NODE   job: ${SLURM_JOB_ID:-<none>}"
    echo "first_listen       : ${first_listen:-NEVER}s   on [${first_listen_fam:-NEVER}]"
    echo "first_http_200     : ${first_200:-NEVER}s"
    echo "uvicorn_logged_at  : ${uvicorn_logged:-NEVER (observed)}"
    echo "watched_for        : $(( $(date +%s) - t0 ))s"
    echo "end_wallclock      : $(date -Iseconds)"
    echo
    echo "INTERPRETATION HINTS:"
    echo " * listen=0 whole window AND 200=NEVER  -> socket never bound in window"
    echo "      (cold-start/stall, OR uvicorn never bound — cross-check log mtime)."
    echo " * listener on [::]:$PORT only + localhost rc=7 + 127.0.0.1 code=200"
    echo "      -> IPv6 (localhost->::1, uvicorn IPv4-only). (Previously deemed improbable.)"
    echo " * listener on 0.0.0.0:$PORT + BOTH curls 200 inside window"
    echo "      -> probe SHOULD have passed; the failing-run log was likely a"
    echo "         different run (truncated, no timestamp) — compare mtimes."
    echo " * first_200 > readiness window (INGESTOR_READY_ATTEMPTS*2s)"
    echo "      -> bound too late: timeout honestly too short for this node."
} >> "$REPORT"

    # copy the run's own log (no timestamps, but mtime + 'Uvicorn running' matter)
    if [ -n "$LOGS_DIR" ] && [ -f "$LOGS_DIR/ingestor-server.log" ]; then
        cp "$LOGS_DIR/ingestor-server.log" "$OUT_DIR/ingestor-server-${NODE}.log" 2>/dev/null || true
        echo "(copied ingestor-server.log -> $OUT_DIR/ingestor-server-${NODE}.log)" >> "$REPORT"
    fi
}
trap 'echo; echo "(interrupted — writing final report)"; finalize; exit 0' INT TERM
finalize

echo
echo "Diagnostic complete."
echo "  Report : $REPORT"
echo "  Commit from the LOGIN node:"
echo "    cd <repo> && git add deploy/singularity/scripts/import_logs/debug-06c/ \\"
echo "      && git commit -m 'logs: debug-06c ingestor readiness diag ($NODE)' && git push"
