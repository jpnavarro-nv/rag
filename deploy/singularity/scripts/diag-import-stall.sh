#!/bin/bash
# ==============================================================================
# diag-import-stall.sh — decide a causa-raiz do cold-start lento do ingestor:
#   (A) chamada de rede HF presa no firewall  vs  (B) page-in squashfuse/Lustre.
# NÃO sobe a stack; só faz imports controlados dentro do SIF e cronometra.
#
# Onde rodar: num NÓ DE COMPUTE (dentro do job, ou `srun --overlap --jobid=$JID
#   -w $NODE bash deploy/singularity/scripts/diag-import-stall.sh`). Idealmente
#   num nó RECÉM-ALOCADO (cache de página frio) — senão tudo vem rápido e não decide.
# Saída: relatório .out commitável em import_logs/debug-06c/ (só *.out/.log/.err
#   sobem; .txt é gitignored). PUSH pelo LOGIN node (compute pode ter outbound
#   bloqueado pelo FortiGate).
#
# Uso:
#   bash diag-import-stall.sh [/caminho/para/ingestor-server.sif]
#   SIF=/outro/caminho.sif bash diag-import-stall.sh
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$SCRIPT_DIR/import_logs/debug-06c"
mkdir -p "$OUTDIR"

NODE="${SLURMD_NODENAME:-$(hostname -s 2>/dev/null || hostname)}"
JOB="${SLURM_JOB_ID:-noslurm}"
REPORT="$OUTDIR/import-stall-${NODE}-${JOB}.out"

# --- localizar o SIF (arg1 > $SIF > default conhecido) ---
SIF="${1:-${SIF:-/gaia/nvidia/partner/rag-test/containers/images/ingestor-server.sif}}"

PYBIN="/workspace/.venv/bin/python"
IMPORT_LIGHT='import transformers'                      # sem rede, sem MinIO -> lento ⟹ page-in (B)
IMPORT_FULL='import nvidia_rag.ingestor_server.server'  # fiel; pode tocar MinIO/rede
OFFLINE_ENV=(--env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 \
             --env HF_HUB_DISABLE_TELEMETRY=1 --env HF_HUB_DISABLE_IMPLICIT_TOKEN=1)
CAP=1200   # teto por teste (s); um stall real ~900s cabe, um hang infinito é cortado

log() { echo "$@" | tee -a "$REPORT"; }

# run_import <label> <sif> <pycode> [args extras p/ singularity, ex: env offline]
run_import() {
  local label="$1" sif="$2" code="$3"; shift 3
  local itlog; itlog="$(mktemp)"
  local start=$SECONDS rc dur
  timeout "$CAP" singularity exec "$@" "$sif" "$PYBIN" -X importtime -c "$code" >/dev/null 2>"$itlog"
  rc=$?; dur=$((SECONDS - start))
  [ "$rc" = 124 ] && dur=">=${CAP} (TIMEOUT)"
  log ""
  log "[$label] elapsed=${dur}s rc=$rc"
  log "    sif=$sif"
  log "    code='$code'  env_extra='$*'"
  log "    -- imports mais pesados (cumulative, us) --"
  grep -iE 'transformers|huggingface|torch|nvidia_rag|pydantic|langchain|milvus|minio|safetensors|tokenizers' \
      "$itlog" 2>/dev/null | tail -12 | sed 's/^/      /' | tee -a "$REPORT"
  rm -f "$itlog"
}

# ============================== cabeçalho ==============================
: > "$REPORT"
log "=============================================================="
log " DIAG IMPORT STALL — ingestor cold-start (A rede HF vs B squashfuse)"
log "=============================================================="
log "node            : $NODE   job: $JOB"
log "wallclock       : $(date '+%FT%T%z')"
log "sif             : $SIF"
if [ ! -f "$SIF" ]; then
  log "ERRO: SIF não encontrado. Passe o caminho: bash $0 /caminho/ingestor-server.sif"
  exit 1
fi
log "sif size        : $(du -h "$SIF" 2>/dev/null | cut -f1)"
log "singularity     : $(command -v singularity || echo ausente)  $(singularity --version 2>/dev/null)"
log "getent localhost: $(getent hosts localhost 2>/dev/null | head -1)"
log "/tmp livre      : $(df -h /tmp 2>/dev/null | awk 'NR==2{print $4" de "$2}')"
log "=============================================================="

# ===== T1 — prova B: Lustre (frio) vs /tmp local vs Lustre de novo (quente) =====
log ""
log "##### T1 — page-in: 'import transformers' (sem rede, sem MinIO) #####"
run_import "T1a-lustre-cold" "$SIF" "$IMPORT_LIGHT"

TMPSIF="/tmp/ing-${JOB}-$$.sif"
log ""
log "[T1 copy] copiando SIF -> $TMPSIF"
cp_start=$SECONDS
if cp "$SIF" "$TMPSIF" 2>>"$REPORT"; then
  log "[T1 copy] elapsed=$((SECONDS - cp_start))s  ($(du -h "$TMPSIF" 2>/dev/null | cut -f1))"
  run_import "T1b-tmp-local"   "$TMPSIF" "$IMPORT_LIGHT"
else
  log "[T1 copy] FALHOU (sem espaço em /tmp?) — pulando T1b"
fi
run_import "T1c-lustre-warm"  "$SIF" "$IMPORT_LIGHT"

# ===== T2 — prova/refuta A: import FIEL, sem vs com env offline =====
log ""
log "##### T2 — rede HF: '$IMPORT_FULL', baseline vs offline #####"
log "(obs: pode falhar/abortar se exigir MinIO/Milvus — o importtime já captura o custo dos libs)"
run_import "T2a-full-baseline" "$SIF" "$IMPORT_FULL"
run_import "T2b-full-offline"  "$SIF" "$IMPORT_FULL" "${OFFLINE_ENV[@]}"

# ===== T3 — se houver um uvicorn de deploy real travado, ver no que está preso =====
log ""
log "##### T3 — uvicorn vivo travado (se existir agora) #####"
UVPID="$(pgrep -f '/workspace/.venv/bin/python.*uvicorn nvidia_rag' 2>/dev/null | head -1)" || true
if [ -n "${UVPID:-}" ]; then
  log "uvicorn pid=$UVPID  etimes=$(ps -o etimes= -p "$UVPID" 2>/dev/null | tr -d ' ')s"
  log "wchan=$(cat /proc/$UVPID/wchan 2>/dev/null)   (connect/sk_wait→A ; fuse_*/wait_on_page/read→B)"
  log "-- fds relevantes (socket externo=A ; .so/gaia/SIF=B) --"
  ls -l /proc/$UVPID/fd 2>/dev/null | grep -iE 'socket|gaia|\.so|/tmp|squashfuse' | sed 's/^/  /' | tee -a "$REPORT"
else
  log "(nenhum uvicorn nvidia_rag rodando agora — T3 pulado)"
fi

# ===== limpeza + SUMÁRIO =====
[ -f "$TMPSIF" ] && rm -f "$TMPSIF"
log ""
log "=============================== SUMÁRIO ==============================="
grep -E '\[T[0-9].*\] elapsed=' "$REPORT" | sed 's/^/  /'
log ""
log "INTERPRETAÇÃO:"
log " * T1a(lustre-frio) LENTO e T1b(/tmp) RÁPIDO  -> B (squashfuse/Lustre). Fix: stagear SIF em /tmp."
log "   - se T1c(lustre-quente) também RÁPIDO -> era page-in frio (warmup/staging resolve)."
log "   - se T1c ainda LENTO -> Lustre é o gargalo mesmo quente -> staging /tmp é essencial."
log " * T1a já RÁPIDO -> cache quente; rode num nó RECÉM-ALOCADO p/ decidir."
log " * T2b(offline) MUITO mais rápido que T2a -> A (rede HF). Fix: env offline (já no working tree)."
log " * T2a≈T2b (ambos ~iguais) -> env HF é no-op p/ o stall (A refutado)."
log " * T3 wchan=fuse_*/read em .so do SIF -> B ; connect/socket externo -> A."
log "=============================================================="
log ""
log "Relatório: $REPORT"
echo ""
echo ">>> Para enviar pelo git (rode no LOGIN node):"
echo "    git add $REPORT && git commit -m 'logs: diag-import-stall ${NODE}-${JOB}' && git push origin feature/singularity-deployment"
