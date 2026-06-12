#!/usr/bin/env bash
# =============================================================================
# diag-minio-call.sh — mede a chamada MinIO REAL do ingestor (a que trava no import)
#
# Objetivo: dar CERTEZA, com números, antes de um deploy completo. Roda dentro do
# MESMO SIF do ingestor e usa o MESMO cliente minio que o nvidia_rag usa
# (minio_operator.py: Minio(endpoint, ..., secure=False) — SEM region), cronometrando
# bucket_exists("default-bucket") — que dispara _get_region (GetBucketLocation) -> HeadBucket,
# a pilha EXATA do stall (import-stall 360917, FORENSIC 360948).
#
# Responde 3 perguntas decisivas:
#   1) 676b2d0 é o fix?  -> compara 127.0.0.1:9010 (pós-fix) vs localhost:9010 (pré-fix, cai em ::1)
#   2) O ingestor (SEM region) é rápido contra 127.0.0.1?  -> amostra repetida durante/após cold start
#   3) region elimina lentidão?  -> compara SEM region vs COM region="us-east-1"
#
# NÃO faz deploy. Requer apenas o MinIO de pé (passo 01 já rodou) no nó.
# Uso:   bash diag-minio-call.sh [port] [samples]
#        (anexar a job vivo:  srun --overlap --jobid=$JID -w $NODE bash .../diag-minio-call.sh)
# =============================================================================
set -u

PORT="${1:-9010}"
SAMPLES="${2:-40}"          # amostras por endpoint (sleep 2s entre elas)
ACCESS="${MINIO_ROOT_USER:-minioadmin}"
SECRET="${MINIO_ROOT_PASSWORD:-minioadmin}"

# Localiza o SIF do ingestor
SIF=""
for c in \
  "${RAG_IMAGES_DIR:-}/ingestor-server.sif" \
  "/gaia/nvidia/partner/rag-test/containers/images/ingestor-server.sif" \
  "$(dirname "$0")/../../containers/images/ingestor-server.sif"; do
  [ -n "$c" ] && [ -f "$c" ] && { SIF="$c"; break; }
done
if [ -z "$SIF" ]; then echo "❌ não achei ingestor-server.sif (passe RAG_IMAGES_DIR)"; exit 1; fi

NODE="$(hostname -s)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="$(dirname "$0")/import_logs/debug-06c"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/diag-minio-call-${NODE}-${TS}.out"

{
echo "================ diag-minio-call ================"
echo "node=$NODE  ts=$TS  port=$PORT  samples=$SAMPLES"
echo "sif=$SIF"
echo "-- getent hosts localhost (esperado: ::1 primeiro nesses nós) --"
getent hosts localhost
echo "================================================="
} | tee "$OUT"

# O probe Python: mede a MESMA chamada do ingestor. http_client com read=30s/retries=1
# só p/ o DIAG não pendurar 1800s — uma amostra >25s já denuncia o stall. NÃO setamos
# region (igual ao ingestor), exceto na rodada de comparação explícita.
singularity exec "$SIF" /workspace/.venv/bin/python - \
    "$PORT" "$SAMPLES" "$ACCESS" "$SECRET" <<'PY' 2>&1 | tee -a "$OUT"
import sys, time, urllib3
from minio import Minio
from minio.error import S3Error

port, samples, access, secret = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

def client(host, region=None):
    http = urllib3.PoolManager(timeout=urllib3.Timeout(connect=5, read=30),
                               retries=urllib3.Retry(total=1))
    kw = dict(access_key=access, secret_key=secret, secure=False, http_client=http)
    if region:
        kw["region"] = region
    return Minio(f"{host}:{port}", **kw)

def measure(c, bucket="default-bucket"):
    t0 = time.monotonic()
    try:
        ok = c.bucket_exists(bucket)   # _get_region (GetBucketLocation) -> HeadBucket
        return (time.monotonic() - t0) * 1000.0, f"ok={ok}"
    except S3Error as e:
        return (time.monotonic() - t0) * 1000.0, f"S3Error:{e.code}"
    except Exception as e:
        return (time.monotonic() - t0) * 1000.0, f"{type(e).__name__}:{str(e)[:60]}"

def run(label, host, region=None):
    print(f"\n##### {label}  (host={host} region={region}) #####", flush=True)
    c = client(host, region)
    ms_list = []
    slow = 0
    for i in range(1, samples + 1):
        ms, res = measure(c)
        ms_list.append(ms)
        if ms > 1000:
            slow += 1
        if i <= 5 or i % 5 == 0 or ms > 1000:
            print(f"  [{i:>3}/{samples}] {ms:8.1f} ms   {res}", flush=True)
        time.sleep(2)
    ms_list.sort()
    n = len(ms_list)
    med = ms_list[n // 2]
    print(f"  --> {label}: min={ms_list[0]:.1f}ms  mediana={med:.1f}ms  "
          f"max={ms_list[-1]:.1f}ms  lentas(>1s)={slow}/{n}", flush=True)
    return ms_list[-1], slow

# 1) PÓS-FIX: o que o ingestor faz hoje (676b2d0) — 127.0.0.1, SEM region
mx127, slow127 = run("127.0.0.1 SEM region (= ingestor real pós-676b2d0)", "127.0.0.1")

# 2) PRÉ-FIX: prova do ::1 — localhost, SEM region (poucas amostras, pode pendurar)
print("\n(localhost: poucas amostras — pode cair em ::1 e levar ~30s cada)", flush=True)
import sys as _s
_orig = samples
try:
    # roda só ~6 amostras p/ não gastar 30s*40
    globals()['samples'] = min(6, _orig)
    mxlh, slowlh = run("localhost SEM region (= pré-676b2d0, ::1)", "localhost")
finally:
    globals()['samples'] = _orig

# 3) COM region em 127.0.0.1 — mede se GetBucketLocation é o que pesa
globals()['samples'] = min(10, _orig)
mxr, slowr = run("127.0.0.1 COM region=us-east-1 (pula GetBucketLocation)", "127.0.0.1", "us-east-1")

print("\n================ VEREDITO ================", flush=True)
print(f"127.0.0.1 sem region : max={mx127:.0f}ms  lentas={slow127}", flush=True)
print(f"localhost  sem region : max={mxlh:.0f}ms  lentas={slowlh}", flush=True)
print(f"127.0.0.1 com region : max={mxr:.0f}ms  lentas={slowr}", flush=True)
print("\nLeitura:", flush=True)
print(" - 127/sem-region SEMPRE rápido (<1s, 0 lentas) -> 676b2d0+gate bastam; ingestor binda em segundos.", flush=True)
print(" - 127/sem-region às vezes LENTO (>5s ou timeouts) -> raiz persiste -> precisa overlay (region+timeout) OU disco local.", flush=True)
print(" - localhost MUITO pior que 127 -> confirma que o ::1 era a causa e o 676b2d0 ataca certo.", flush=True)
print(" - com-region << sem-region em 127 -> GetBucketLocation é o gargalo -> overlay com region resolve.", flush=True)
PY

echo "" | tee -a "$OUT"
echo "✅ Relatório: $OUT" | tee -a "$OUT"
echo "Enviar (no login node):" | tee -a "$OUT"
echo "  git add $OUT && git commit -m 'logs: diag-minio-call $NODE-$TS' && git push origin feature/singularity-deployment" | tee -a "$OUT"
