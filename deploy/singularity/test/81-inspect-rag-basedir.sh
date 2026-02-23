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

echo "--- Exec sessions ---"
ls -dt $RAG_BASE_DIR/exec_* 2>/dev/null || echo "(nenhuma)"
echo ""
echo "Current exec: ${RAG_EXEC_DIR:-(none)}"
echo ""

echo "--- DB (persistente) ---"
du -sh $RAG_DB_DIR/* 2>/dev/null || echo "(db/ vazio ou ausente)"
echo ""

echo "--- PID files ---"
if [ -n "$RAG_RUNTIME_DIR" ]; then
    ls -la $RAG_RUNTIME_DIR/pids/ 2>/dev/null || echo "(diretório ausente)"
    echo ""
    echo "--- Conteúdo de cada PID file ---"
    for f in $RAG_RUNTIME_DIR/pids/*.pid; do
        [ -f "$f" ] && echo "$f: $(cat "$f")"
    done
else
    echo "(sem exec ativo)"
fi
echo ""

echo "--- ingestor-venv-bin (overlay cache) ---"
if [ -n "$RAG_RUNTIME_DIR" ] && [ -d "$RAG_RUNTIME_DIR/ingestor-venv-bin" ]; then
    ls -lh $RAG_RUNTIME_DIR/ingestor-venv-bin/ | head -20
    echo ""
    echo "  bulk_writer:"
    ls -lah $RAG_RUNTIME_DIR/ingestor-venv-bin/bulk_writer 2>/dev/null \
        || echo "  (ausente)"
    echo ""
    echo "  tipo do bulk_writer:"
    file $RAG_RUNTIME_DIR/ingestor-venv-bin/bulk_writer 2>/dev/null \
        || echo "  (ausente)"
else
    echo "(diretório ausente)"
fi
echo ""

echo "--- Logs: timestamps ---"
if [ -n "$RAG_LOGS_DIR" ]; then
    ls -lht $RAG_LOGS_DIR/ 2>/dev/null || echo "(diretório ausente)"
else
    echo "(sem exec ativo)"
fi
echo ""

echo "--- Últimas 10 linhas de cada log de app layer ---"
if [ -n "$RAG_LOGS_DIR" ]; then
    for log in nv-ingest ingestor-server rag-server rag-frontend; do
        echo "=== $log.log ==="
        tail -10 $RAG_LOGS_DIR/$log.log 2>/dev/null || echo "(ausente)"
        echo ""
    done
else
    echo "(sem exec ativo)"
fi

echo "--- runtime/nv-ingest-data ---"
if [ -n "$RAG_RUNTIME_DIR" ]; then
    du -sh $RAG_RUNTIME_DIR/nv-ingest-data/ 2>/dev/null || echo "(ausente)"
    ls $RAG_RUNTIME_DIR/nv-ingest-data/ 2>/dev/null
else
    echo "(sem exec ativo)"
fi
echo ""

echo "--- runtime/ingestor-temp ---"
if [ -n "$RAG_RUNTIME_DIR" ]; then
    du -sh $RAG_RUNTIME_DIR/ingestor-temp/ 2>/dev/null || echo "(ausente)"
    ls $RAG_RUNTIME_DIR/ingestor-temp/ 2>/dev/null
else
    echo "(sem exec ativo)"
fi
echo ""

echo "--- Containers images (.sif) ---"
ls -lh $RAG_IMAGES_DIR/*.sif 2>/dev/null || echo "(ausente)"
echo ""

echo "=== Fim da inspeção ==="

} | tee "$OUTFILE"

echo ""
echo "Salvo em: $OUTFILE"
