#!/bin/bash
# ==============================================================================
# catch-ingestor-hang.sh — captura forense do uvicorn do ingestor TRAVADO ao vivo.
# Decide DEFINITIVAMENTE onde o startup pendura (chamada MinIO / page-in squashfuse /
# rede externa / lock), coisa que os logs não mostram.
#
# Onde rodar: num NÓ DE COMPUTE, EM PARALELO a um deploy que está no passo 06
#   (segundo terminal):  srun --overlap --jobid=$JID -w $NODE bash deploy/singularity/scripts/catch-ingestor-hang.sh
#   (o JID/NODE do job que está rodando o ./submit.sh)
# O script espera o uvicorn aparecer, confirma que está VIVO mas SEM bind em :8082
# por >THRESHOLD s, então faz o dump e sai (one-shot). Escreve .out commitável.
# Push pelo LOGIN node.
#
# Env: THRESHOLD_S (default 120) = quanto esperar de stall antes de capturar.
#      STRACE_S (default 20)     = duração do strace.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$SCRIPT_DIR/import_logs/debug-06c"; mkdir -p "$OUTDIR"
NODE="${SLURMD_NODENAME:-$(hostname -s 2>/dev/null || hostname)}"
JOB="${SLURM_JOB_ID:-noslurm}"
REPORT="$OUTDIR/hang-catch-${NODE}-${JOB}.out"
PORT="${INGESTOR_PORT:-8082}"
PAT='/workspace/.venv/bin/python.*uvicorn nvidia_rag'
THRESHOLD_S="${THRESHOLD_S:-120}"
STRACE_S="${STRACE_S:-20}"

log() { echo "$@" | tee -a "$REPORT"; }

: > "$REPORT"
log "=============================================================="
log " CATCH INGESTOR HANG — pilha ao vivo do uvicorn travado"
log "=============================================================="
log "node=$NODE job=$JOB port=$PORT threshold=${THRESHOLD_S}s wallclock=$(date '+%FT%T%z')"

# 1) esperar o uvicorn nascer
log "[..] aguardando o processo uvicorn aparecer (pgrep)..."
PID=""
for _ in $(seq 1 600); do          # até ~20min
  PID="$(pgrep -f "$PAT" 2>/dev/null | head -1)" || true
  [ -n "$PID" ] && break
  sleep 2
done
if [ -z "$PID" ]; then
  log "ERRO: uvicorn nvidia_rag não apareceu. Rode durante o passo 06."
  exit 1
fi
log "[ok] uvicorn PID=$PID  etimes=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')s"

# 2) esperar confirmar STALL: vivo + sem listener em :PORT por THRESHOLD_S
log "[..] confirmando stall (vivo + porta $PORT sem bind) por ${THRESHOLD_S}s..."
stall=0
while [ "$stall" -lt "$THRESHOLD_S" ]; do
  ps -p "$PID" >/dev/null 2>&1 || { log "uvicorn morreu (PID $PID) — não é stall, é crash."; exit 0; }
  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    log "[ok] porta $PORT JÁ tem listener — o ingestor subiu (sem stall agora). etimes=$(ps -o etimes= -p "$PID"|tr -d ' ')s. Nada a capturar."
    exit 0
  fi
  sleep 5; stall=$((stall + 5))
done
log "[!!] STALL confirmado: PID $PID vivo, etimes=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')s, SEM listener em :$PORT após ${THRESHOLD_S}s. Capturando..."

# 3) DUMP forense
log ""; log "===== cmdline ====="
tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null | tee -a "$REPORT"; log ""

log ""; log "===== /proc/$PID/wchan (função do kernel onde bloqueia) ====="
cat /proc/$PID/wchan 2>/dev/null | tee -a "$REPORT"; log ""

log ""; log "===== /proc/$PID/stack (pilha do kernel) ====="
cat /proc/$PID/stack 2>/dev/null | tee -a "$REPORT" || log "(sem permissão p/ stack)"

log ""; log "===== py-spy dump (pilha Python — o smoking gun, se py-spy existir) ====="
if command -v py-spy >/dev/null 2>&1; then
  py-spy dump --pid "$PID" 2>&1 | tee -a "$REPORT"
else
  log "(py-spy ausente — tentando faulthandler via SIGABRT seria destrutivo; pulando)"
fi

log ""; log "===== conexões TCP do processo (há algo preso p/ MinIO :9010 / externo?) ====="
log "-- ss por pid --"
ss -tanp 2>/dev/null | grep -E "pid=$PID" | tee -a "$REPORT" || log "(ss não casou pid)"
log "-- sockets nos fds + estado em /proc/net/tcp (2332=9010 minio,2382=9090,1F92=8082) --"
for fd in /proc/$PID/fd/*; do
  tgt=$(readlink "$fd" 2>/dev/null)
  case "$tgt" in socket:*) ino="${tgt#socket:[}"; ino="${ino%]}";
    grep -iE "[0-9]+: [0-9A-F]+:[0-9A-F]+ [0-9A-F]+:[0-9A-F]+" /proc/$PID/net/tcp 2>/dev/null \
      | awk -v i="$ino" '$10==i{print}' | tee -a "$REPORT";; esac
done

log ""; log "===== strace ${STRACE_S}s (no que pendura: recvfrom/connect=rede; read/openat=squashfuse; futex=lock) ====="
if command -v strace >/dev/null 2>&1; then
  timeout "$STRACE_S" strace -f -tt -T -p "$PID" -e trace=connect,sendto,recvfrom,read,openat,futex,poll,select 2>&1 | tail -60 | tee -a "$REPORT"
else
  log "(strace ausente)"
fi

log ""; log "===== files abertos relevantes (.so/gaia/squashfuse/tmp) ====="
ls -l /proc/$PID/fd 2>/dev/null | grep -iE 'gaia|\.so|squashfuse|/tmp|socket' | sed 's/^/  /' | tee -a "$REPORT"

log ""; log "=============================================================="
log "Relatório: $REPORT"
echo ""
echo ">>> Enviar pelo LOGIN node:"
echo "    git add $REPORT && git commit -m 'logs: hang-catch ${NODE}-${JOB}' && git push origin feature/singularity-deployment"
