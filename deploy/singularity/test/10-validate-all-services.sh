#!/bin/bash
# Validate All Services
# Complete healthcheck and connectivity test for the entire RAG stack
#
# This script validates:
# - Infrastructure: etcd, MinIO, Milvus
# - Redis
# - NIM Models: Embedding, Ranking, LLM, VLM, OCR, YOLOX
# - NV-Ingest Microservice
# - Ingestor Server
# - RAG Server

# NOTE: no set -e — validation must continue past individual failures

# Load configuration
source "$(dirname "$0")/00-config.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# ==============================================================================
# Validation Functions
# ==============================================================================

check_service_http() {
    local name=$1
    local url=$2
    local expected_status=${3:-200}

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    local status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [ "$status_code" = "$expected_status" ] || [ "$status_code" = "200" ]; then
        echo -e "   ${GREEN}✅${NC} $name - HTTP $status_code"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "   ${RED}❌${NC} $name - HTTP $status_code (expected $expected_status)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

check_service_port() {
    local name=$1
    local host=$2
    local port=$3

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if nc -z $host $port > /dev/null 2>&1; then
        echo -e "   ${GREEN}✅${NC} $name - Port $port open"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "   ${RED}❌${NC} $name - Port $port closed"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

check_service_pid() {
    local name=$1
    local pid_file=$2

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [ ! -f "$pid_file" ]; then
        echo -e "   ${RED}❌${NC} $name - PID file not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    local pid=$(cat "$pid_file")
    if ps -p $pid > /dev/null 2>&1; then
        echo -e "   ${GREEN}✅${NC} $name - Process running (PID $pid)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "   ${RED}❌${NC} $name - Process not running (stale PID $pid)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

print_section() {
    echo ""
    echo -e "${BLUE}=====================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=====================================================================${NC}"
}

# ==============================================================================
# Main Validation
# ==============================================================================

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         RAG Stack Complete Validation                              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ==============================================================================
# 1. Infrastructure Services
# ==============================================================================
print_section "1. Infrastructure Services (etcd, MinIO, Milvus)"

check_service_pid "etcd" "$RAG_RUNTIME_DIR/pids/etcd.pid"
check_service_http "etcd health" "http://localhost:2379/health"

check_service_pid "MinIO" "$RAG_RUNTIME_DIR/pids/minio.pid"
check_service_http "MinIO health" "http://localhost:9010/minio/health/live"

check_service_pid "Milvus" "$RAG_RUNTIME_DIR/pids/milvus.pid"
check_service_http "Milvus health" "http://localhost:9091/healthz"
check_service_port "Milvus API" "localhost" "19530"

# ==============================================================================
# 2. Redis
# ==============================================================================
print_section "2. Redis (Message Queue)"

check_service_pid "Redis" "$RAG_RUNTIME_DIR/pids/redis.pid"
check_service_port "Redis" "localhost" "6379"

# ==============================================================================
# 3. NIM Models
# ==============================================================================
print_section "3. NIM Models"

# Core models
check_service_pid "Embedding NIM" "$RAG_RUNTIME_DIR/pids/nemoretriever-embedding.pid"
check_service_http "Embedding NIM" "http://localhost:9080/v1/health/ready"

check_service_pid "Ranking NIM" "$RAG_RUNTIME_DIR/pids/nemoretriever-ranking.pid"
check_service_http "Ranking NIM" "http://localhost:1976/v1/health/ready"

check_service_pid "LLM NIM" "$RAG_RUNTIME_DIR/pids/nim-llm.pid"
check_service_http "LLM NIM" "http://localhost:8999/v1/health/ready"

check_service_pid "VLM NIM" "$RAG_RUNTIME_DIR/pids/vlm.pid"
check_service_http "VLM NIM" "http://localhost:1977/v1/health/ready"

# Document processing models
check_service_pid "Page Elements" "$RAG_RUNTIME_DIR/pids/page-elements.pid"
check_service_http "Page Elements" "http://localhost:8000/v1/health/ready"

check_service_pid "Graphic Elements" "$RAG_RUNTIME_DIR/pids/graphic-elements.pid"
check_service_http "Graphic Elements" "http://localhost:8003/v1/health/ready"

check_service_pid "Table Structure" "$RAG_RUNTIME_DIR/pids/table-structure.pid"
check_service_http "Table Structure" "http://localhost:8016/v1/health/ready"

check_service_pid "PaddleOCR" "$RAG_RUNTIME_DIR/pids/paddle-ocr.pid"
check_service_http "PaddleOCR" "http://localhost:8009/v1/health/ready"

# ==============================================================================
# 4. NV-Ingest Microservice
# ==============================================================================
print_section "4. NV-Ingest Microservice"

check_service_pid "NV-Ingest" "$RAG_RUNTIME_DIR/pids/nv-ingest.pid"
check_service_http "NV-Ingest" "http://localhost:7670/v1/health/ready"
# Broker port 7671 is not opened in Singularity: NV-Ingest uses Redis (6379) as message broker

# ==============================================================================
# 5. Application Servers
# ==============================================================================
print_section "5. Application Servers"

check_service_pid "Ingestor Server" "$RAG_RUNTIME_DIR/pids/ingestor-server.pid"
check_service_http "Ingestor Server" "http://localhost:8082/health"
check_service_http "Ingestor API Docs" "http://localhost:8082/docs"

check_service_pid "RAG Server" "$RAG_RUNTIME_DIR/pids/rag-server.pid"
check_service_http "RAG Server" "http://localhost:8081/health"
check_service_http "RAG API Docs" "http://localhost:8081/docs"

# ==============================================================================
# 6. Frontend
# ==============================================================================
print_section "6. Frontend (Web UI)"

check_service_pid "Frontend" "$RAG_RUNTIME_DIR/pids/rag-frontend.pid"
check_service_http "Frontend UI" "http://localhost:3000/"

# ==============================================================================
# Summary
# ==============================================================================
print_section "Validation Summary"

echo ""
echo "Total Checks:  $TOTAL_CHECKS"
echo -e "Passed:        ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Failed:        ${RED}$FAILED_CHECKS${NC}"
echo ""

if [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅  ALL SERVICES OPERATIONAL - RAG Stack Ready for Use!          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    NODE_IP=$(hostname -I | awk '{print $1}')
    echo "🎯 Quick Access URLs (use compute node IP from your browser):"
    echo "   • Web UI:          http://${NODE_IP}:3000"
    echo "   • RAG Server API:  http://${NODE_IP}:8081/docs"
    echo "   • Ingestor API:    http://${NODE_IP}:8082/docs"
    echo "   • MinIO Console:   http://${NODE_IP}:9011"
    echo ""
    echo "📝 Next Steps:"
    echo "   1. Use SSH tunnel to access from your laptop"
    echo "   2. Test document ingestion via Ingestor API"
    echo "   3. Query documents via RAG Server API"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  SOME SERVICES FAILED - Check logs for details                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "📋 Troubleshooting:"
    echo "   • Check logs in: $RAG_LOGS_DIR/"
    echo "   • Review failed services above"
    echo "   • Ensure NGC_API_KEY is set correctly"
    echo "   • Verify GPU resources are available"
    echo ""
    echo "🔧 Common Issues:"
    echo "   • NIMs not ready: Models may still be loading (check logs)"
    echo "   • Port conflicts: Check if ports are already in use"
    echo "   • GPU memory: Ensure sufficient GPU memory for all NIMs"
    exit 1
fi
