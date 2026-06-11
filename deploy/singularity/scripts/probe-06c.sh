#!/bin/bash
# ==============================================================================
# probe-06c.sh — sonda one-shot de readiness do Ingestor (8082), AUTODETECTÁVEL.
#
# Aproveita um deploy JÁ EM ANDAMENTO: descobre sozinho o job RUNNING do usuário
# e o nó, ataca o 8082 via `srun --overlap`, e SALVA a saída em
# import_logs/debug-06c/ (commitável: *.out não é gitignored). Rode do LOGIN node.
#
# Uso:
#   bash probe-06c.sh                 # autodetecta job e nó
#   JID=123456 bash probe-06c.sh      # força o job
#   JID=123456 NODE=gaiab05n08 bash probe-06c.sh
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/import_logs/debug-06c"
PORT=8082

# ---- autodetect job / nó ----------------------------------------------------
JID="${JID:-$(squeue -h -u "$USER" -t RUNNING -o '%i' | head -1)}"
if [ -z "$JID" ]; then
    echo "ERRO: nenhum job RUNNING encontrado p/ $USER. Liste com: squeue -u $USER" >&2
    echo "Depois rode: JID=<id> bash $0" >&2
    exit 1
fi
NODE="${NODE:-$(squeue -h -j "$JID" -o '%N')}"
if [ -z "$NODE" ]; then
    echo "ERRO: job $JID sem nó atribuído (PENDING?). Aguarde sair de PENDING." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/probe-${NODE}-${JID}.out"
echo "JID=$JID  NODE=$NODE"
echo "relatório -> $REPORT"

# ---- a sonda decisiva, rodada no nó via srun --------------------------------
{
    echo "=============================================================="
    echo " INGESTOR PROBE one-shot   node=$NODE  job=$JID  port=$PORT"
    echo " wallclock=$(date -Iseconds)"
    echo "=============================================================="
} > "$REPORT"

srun --overlap --jobid="$JID" -w "$NODE" bash -c '
    echo "== resolução de nomes =="
    getent hosts localhost
    getent hosts ip6-localhost
    grep -E "127\.0\.0\.1|::1|localhost" /etc/hosts
    echo "== listener (com PID) =="
    ss -ltnp "sport = :'"$PORT"'"
    echo "== /proc/net/tcp6 (porta 1F92) =="
    grep -i ":1F92 " /proc/net/tcp6 2>/dev/null
    echo "== ps uvicorn/singularity =="
    ps -eo pid,ppid,etimes,cmd 2>/dev/null | grep -E "uvicorn|singularity|apptainer" | grep -v grep
    echo "== probes (rc do shell: 7=conn refused  28=timeout  6=DNS  0=ok) =="
    curl -sS -o /dev/null -w "localhost  code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://localhost:'"$PORT"'/health; echo "  rc=$?"
    curl -sS -o /dev/null -w "127.0.0.1  code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://127.0.0.1:'"$PORT"'/health; echo "  rc=$?"
    curl -sS -o /dev/null -w "[::1]      code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://[::1]:'"$PORT"'/health; echo "  rc=$?"
' 2>&1 | tee -a "$REPORT"

echo
echo "Feito. Commit do LOGIN node:"
echo "  cd \$(git rev-parse --show-toplevel) \\"
echo "    && git add deploy/singularity/scripts/import_logs/debug-06c/ \\"
echo "    && git commit -m 'logs: debug-06c probe ($NODE, job $JID)' && git push"
