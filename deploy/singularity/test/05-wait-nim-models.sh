#!/bin/bash
# Wait for NIM Models to become ready
# Run after 04-start-nim-models.sh
#
# This script checks health endpoints of all 8 NIMs and waits until they're ready.
# Models can take 5-10 minutes to load on first startup.

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================================================
# Configuration
# ==============================================================================

# NIM ports (must match 04-start-nim-models.sh)
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
RANKING_PORT=${RANKING_PORT:-1976}
LLM_PORT=${LLM_PORT:-8999}
VLM_PORT=${VLM_PORT:-8997}
PAGE_ELEMENTS_PORT=${PAGE_ELEMENTS_PORT:-8000}
GRAPHIC_ELEMENTS_PORT=${GRAPHIC_ELEMENTS_PORT:-8003}
TABLE_STRUCTURE_PORT=${TABLE_STRUCTURE_PORT:-8006}
PADDLE_OCR_PORT=${PADDLE_OCR_PORT:-8009}

# Timeouts
MAX_WAIT_TIME=600  # 10 minutes total
CHECK_INTERVAL=5   # Check every 5 seconds

# ==============================================================================
# Healthcheck Functions
# ==============================================================================

check_nim_health() {
    local name=$1
    local port=$2
    local endpoint=$3

    if curl -s "http://localhost:${port}${endpoint}" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

wait_for_service() {
    local name=$1
    local port=$2
    local endpoint=$3
    local elapsed=0

    echo -n "   Waiting for $name (port $port)..."

    while [ $elapsed -lt $MAX_WAIT_TIME ]; do
        if check_nim_health "$name" "$port" "$endpoint"; then
            echo -e " ${GREEN}✅ Ready${NC} (${elapsed}s)"
            return 0
        fi
        sleep $CHECK_INTERVAL
        elapsed=$((elapsed + CHECK_INTERVAL))
        echo -n "."
    done

    echo -e " ${RED}❌ Timeout${NC} (${MAX_WAIT_TIME}s)"
    return 1
}

# ==============================================================================
# Main
# ==============================================================================

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Waiting for NIM Models to Become Ready                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "This may take 5-10 minutes on first startup while models load..."
echo ""

# Track results
READY_COUNT=0
FAILED_COUNT=0
START_TIME=$(date +%s)

# ==============================================================================
# Check Language Models
# ==============================================================================
echo "=== Language Models ==="
echo ""

if wait_for_service "Embedding NIM" $EMBEDDING_PORT "/v1/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "Ranking NIM" $RANKING_PORT "/v1/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "LLM NIM" $LLM_PORT "/v1/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "VLM NIM" $VLM_PORT "/v1/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# ==============================================================================
# Check Document Processing Models
# ==============================================================================
echo ""
echo "=== Document Processing Models ==="
echo ""

if wait_for_service "Page Elements (YOLOX)" $PAGE_ELEMENTS_PORT "/v2/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "Graphic Elements (YOLOX)" $GRAPHIC_ELEMENTS_PORT "/v2/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "Table Structure (YOLOX)" $TABLE_STRUCTURE_PORT "/v2/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

if wait_for_service "PaddleOCR" $PADDLE_OCR_PORT "/v2/health/ready"; then
    READY_COUNT=$((READY_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# ==============================================================================
# Summary
# ==============================================================================
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Summary"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Total NIMs:    8"
echo -e "Ready:         ${GREEN}${READY_COUNT}${NC}"
echo -e "Failed:        ${RED}${FAILED_COUNT}${NC}"
echo "Total time:    ${TOTAL_TIME}s"
echo ""

if [ $FAILED_COUNT -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  All NIMs Ready - Proceeding to Next Step                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next: Run 06-start-nv-ingest-ms.sh to start NV-Ingest microservice"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  Some NIMs Failed - Check logs for details                    ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  • Check logs: ls -lh $RAG_LOGS_DIR/"
    echo "  • View specific log: tail -100 $RAG_LOGS_DIR/nim-llm.log"
    echo "  • Check instances: singularity instance list"
    echo "  • GPU memory: nvidia-smi"
    echo ""
    echo "Common issues:"
    echo "  • Insufficient GPU memory (check nvidia-smi)"
    echo "  • NGC_API_KEY not set or invalid"
    echo "  • Model cache issues (check disk space)"
    exit 1
fi
