#!/bin/bash
# Drop all Milvus collections (and optionally MinIO bucket data)
# Use before a full reimport test to guarantee a clean state.
#
# Usage:
#   ./80-drop-milvus-collections.sh           # interactive confirmation
#   ./80-drop-milvus-collections.sh --yes     # skip confirmation (CI / scripted use)
#   ./80-drop-milvus-collections.sh --minio   # also purge MinIO bucket
#   ./80-drop-milvus-collections.sh --yes --minio

source "$(dirname "$0")/00-config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

MILVUS_HOST=${MILVUS_HOST:-localhost}
MILVUS_PORT=${MILVUS_PORT:-19530}
MINIO_HOST=${MINIO_HOST:-localhost}
MINIO_PORT=${MINIO_PORT:-9010}
MINIO_BUCKET=${MINIO_BUCKET:-a-bucket}   # default bucket used by ingestor-server

SKIP_CONFIRM=0
PURGE_MINIO=0

for arg in "$@"; do
    case "$arg" in
        --yes)   SKIP_CONFIRM=1 ;;
        --minio) PURGE_MINIO=1  ;;
    esac
done

# ==============================================================================
# Prerequisite check
# ==============================================================================

echo "=== Drop Milvus Collections ==="
echo ""

if ! nc -z "$MILVUS_HOST" "$MILVUS_PORT" > /dev/null 2>&1; then
    echo "❌ Milvus não está acessível em $MILVUS_HOST:$MILVUS_PORT"
    echo "   Execute 01-start-infrastructure.sh primeiro."
    exit 1
fi
echo "✅ Milvus acessível em $MILVUS_HOST:$MILVUS_PORT"

if [ ! -f "$RAG_IMAGES_DIR/ingestor-server.sif" ]; then
    echo "❌ ingestor-server.sif não encontrado em $RAG_IMAGES_DIR"
    exit 1
fi

# ==============================================================================
# Listar coleções existentes
# ==============================================================================

echo ""
echo "Listando coleções em Milvus..."

COLLECTIONS=$(singularity exec \
    --env PYTHONPATH="" \
    "$RAG_IMAGES_DIR/ingestor-server.sif" \
    python3 -c "
from pymilvus import connections, utility
connections.connect(uri='http://${MILVUS_HOST}:${MILVUS_PORT}')
cols = utility.list_collections()
if cols:
    for c in sorted(cols):
        print(c)
else:
    print('__EMPTY__')
" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "❌ Falha ao conectar ao Milvus via pymilvus."
    echo "   Verifique se o Milvus está rodando e acessível."
    exit 1
fi

if [ "$COLLECTIONS" = "__EMPTY__" ]; then
    echo "   (nenhuma coleção encontrada — Milvus já está limpo)"
    echo ""
    echo "✅ Nada a fazer."
    exit 0
fi

echo ""
echo "Coleções encontradas:"
while IFS= read -r col; do
    echo "   - $col"
done <<< "$COLLECTIONS"
COL_COUNT=$(echo "$COLLECTIONS" | wc -l)
echo ""
echo "Total: $COL_COUNT coleção(ões)"

if [ "$PURGE_MINIO" -eq 1 ]; then
    echo ""
    echo "⚠️  MinIO: bucket '$MINIO_BUCKET' também será purgado."
fi

# ==============================================================================
# Confirmação
# ==============================================================================

echo ""
if [ "$SKIP_CONFIRM" -eq 0 ]; then
    echo "⚠️  ATENÇÃO: Esta operação é IRREVERSÍVEL."
    echo "   Todos os vetores e metadados serão apagados permanentemente."
    echo ""
    read -r -p "   Digite 'DROP' para confirmar: " CONFIRM
    if [ "$CONFIRM" != "DROP" ]; then
        echo ""
        echo "Operação cancelada."
        exit 0
    fi
fi

# ==============================================================================
# Drop das coleções
# ==============================================================================

echo ""
echo "Removendo coleções..."

FAILED=0

singularity exec \
    --env PYTHONPATH="" \
    "$RAG_IMAGES_DIR/ingestor-server.sif" \
    python3 -c "
import sys
from pymilvus import connections, utility, Collection

connections.connect(uri='http://${MILVUS_HOST}:${MILVUS_PORT}')
cols = utility.list_collections()

failed = 0
for col in sorted(cols):
    try:
        Collection(col).drop()
        print(f'   ✅ Dropped: {col}')
    except Exception as e:
        print(f'   ❌ Falha ao dropar {col}: {e}', file=sys.stderr)
        failed += 1

sys.exit(failed)
" 2>&1

FAILED=$?

# ==============================================================================
# Purge MinIO (opcional)
# ==============================================================================

if [ "$PURGE_MINIO" -eq 1 ]; then
    echo ""
    echo "Purgando bucket MinIO '$MINIO_BUCKET'..."

    if ! nc -z "$MINIO_HOST" "$MINIO_PORT" > /dev/null 2>&1; then
        echo "   ❌ MinIO não acessível em $MINIO_HOST:$MINIO_PORT — pulando purge."
    else
        singularity exec \
            --env PYTHONPATH="" \
            "$RAG_IMAGES_DIR/ingestor-server.sif" \
            python3 -c "
from minio import Minio
from minio.error import S3Error

client = Minio('${MINIO_HOST}:${MINIO_PORT}',
               access_key='${MINIO_ROOT_USER}',
               secret_key='${MINIO_ROOT_PASSWORD}',
               secure=False)

bucket = '${MINIO_BUCKET}'
try:
    if not client.bucket_exists(bucket):
        print(f'   (bucket {bucket!r} não existe — nada a purgar)')
    else:
        objects = list(client.list_objects(bucket, recursive=True))
        if not objects:
            print(f'   (bucket {bucket!r} já está vazio)')
        else:
            for obj in objects:
                client.remove_object(bucket, obj.object_name)
            print(f'   ✅ {len(objects)} objeto(s) removido(s) do bucket {bucket!r}')
except S3Error as e:
    print(f'   ❌ Erro MinIO: {e}')
    raise SystemExit(1)
" 2>&1

        if [ $? -ne 0 ]; then
            echo "   ⚠️  Falha no purge do MinIO (não crítico — collections já foram dropadas)"
        fi
    fi
fi

# ==============================================================================
# Limpar overlay cache do ingestor-server (garante setup one-time limpo)
# ==============================================================================

INGESTOR_BIN_OVERLAY="$RAG_RUNTIME_DIR/ingestor-venv-bin"
if [ -d "$INGESTOR_BIN_OVERLAY" ]; then
    echo ""
    echo "Limpando overlay cache do ingestor-server..."
    rm -rf "$INGESTOR_BIN_OVERLAY"
    echo "   ✅ $INGESTOR_BIN_OVERLAY removido (será recriado no próximo start do 07)"
fi

# ==============================================================================
# Resultado
# ==============================================================================

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== Drop concluído ==="
    echo "✅ Todas as coleções removidas."
    echo ""
    echo "Próximos passos:"
    echo "   1. Se a app layer está rodando: ./89-stop-app-layer.sh"
    echo "   2. Subir 06 e 07: ./06-start-nv-ingest-ms.sh && ./07-start-ingest-server.sh"
    echo "   3. Rodar cenpes_import.py"
else
    echo "=== Drop concluído com erros ==="
    echo "⚠️  $FAILED coleção(ões) não puderam ser removidas."
    echo "   Verifique a saída acima para detalhes."
    exit 1
fi
