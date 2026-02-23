#!/bin/bash
# Inspect RAG_BASE_DIR persistent state before starting containers.
# Saves output to a timestamped .txt file for analysis.
#
# Usage: ./81-inspect-rag-basedir.sh

source "$(dirname "$0")/00-config.sh"

OUTFILE="$(dirname "$0")/../outputs_debug/basedir-inspect-$(date +%Y-%m-%d_%H-%M).txt"
mkdir -p "$(dirname "$OUTFILE")"

{
echo "=== RAG_BASE_DIR Inspection ==="
echo "Timestamp: $(date)"
echo "Host:      $(hostname)"
echo "RAG_BASE_DIR: $RAG_BASE_DIR"
echo ""

echo "--- Estrutura geral (tamanhos) ---"
du -sh $RAG_BASE_DIR/* 2>/dev/null
echo ""

echo "--- PID files ---"
ls -la $RAG_BASE_DIR/runtime/pids/ 2>/dev/null || echo "(diretório ausente)"
echo ""

echo "--- Conteúdo de cada PID file ---"
for f in $RAG_BASE_DIR/runtime/pids/*.pid; do
    [ -f "$f" ] && echo "$f: $(cat "$f")"
done
echo ""

echo "--- ingestor-venv-bin (overlay cache) ---"
if [ -d "$RAG_BASE_DIR/runtime/ingestor-venv-bin" ]; then
    ls -lh $RAG_BASE_DIR/runtime/ingestor-venv-bin/ | head -20
    echo ""
    echo "  bulk_writer:"
    ls -lah $RAG_BASE_DIR/runtime/ingestor-venv-bin/bulk_writer 2>/dev/null \
        || echo "  (ausente)"
    echo ""
    echo "  tipo do bulk_writer:"
    file $RAG_BASE_DIR/runtime/ingestor-venv-bin/bulk_writer 2>/dev/null \
        || echo "  (ausente)"
else
    echo "(diretório ausente — será criado pelo 07 no primeiro start)"
fi
echo ""

echo "--- Logs: timestamps ---"
ls -lht $RAG_BASE_DIR/logs/ 2>/dev/null || echo "(diretório ausente)"
echo ""

echo "--- Últimas 10 linhas de cada log de app layer ---"
for log in nv-ingest ingestor-server rag-server rag-frontend; do
    echo "=== $log.log ==="
    tail -10 $RAG_BASE_DIR/logs/$log.log 2>/dev/null || echo "(ausente)"
    echo ""
done

echo "--- runtime/nv-ingest-data ---"
du -sh $RAG_BASE_DIR/runtime/nv-ingest-data/ 2>/dev/null || echo "(ausente)"
ls $RAG_BASE_DIR/runtime/nv-ingest-data/ 2>/dev/null
echo ""

echo "--- runtime/ingestor-temp ---"
du -sh $RAG_BASE_DIR/runtime/ingestor-temp/ 2>/dev/null || echo "(ausente)"
ls $RAG_BASE_DIR/runtime/ingestor-temp/ 2>/dev/null
echo ""

echo "--- Containers images (.sif) ---"
ls -lh $RAG_BASE_DIR/containers/images/*.sif 2>/dev/null || echo "(ausente)"
echo ""

echo "=== Fim da inspeção ==="

} | tee "$OUTFILE"

echo ""
echo "Salvo em: $OUTFILE"
