#!/bin/bash
# Test connectivity to infrastructure services

set -e

# Load configuration
source "$(dirname "$0")/00-config.sh"

echo "=== Testing Infrastructure Connectivity ==="
echo ""

# ==============================================================================
# Test etcd
# ==============================================================================
echo "[1/3] Testing etcd..."
if curl -s http://$ETCD_HOST:$ETCD_PORT/health > /dev/null 2>&1; then
    echo "   ✅ etcd is responding"
else
    echo "   ❌ etcd is NOT responding"
    echo "   Check logs: $RAG_LOGS_DIR/etcd.log"
fi

# ==============================================================================
# Test MinIO
# ==============================================================================
echo "[2/3] Testing MinIO..."
if curl -s http://$MINIO_HOST:$MINIO_PORT/minio/health/live > /dev/null 2>&1; then
    echo "   ✅ MinIO is responding"
else
    echo "   ❌ MinIO is NOT responding"
    echo "   Check logs: $RAG_LOGS_DIR/minio.log"
fi

# ==============================================================================
# Test Milvus
# ==============================================================================
echo "[3/3] Testing Milvus..."
# Milvus doesn't have simple HTTP health endpoint, check if port is listening
if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$MILVUS_HOST/$MILVUS_PORT" 2>/dev/null; then
    echo "   ✅ Milvus port is listening"
else
    echo "   ⚠️  Milvus port not responding yet (may still be starting)"
    echo "   Check logs: $RAG_LOGS_DIR/milvus.log"
    echo "   Milvus can take 30-60s to fully start"
fi

echo ""
echo "=== Service Status ==="
singularity instance list

echo ""
echo "=== Instance Logs ==="
echo "To check logs:"
echo "  tail -f $RAG_LOGS_DIR/etcd.log"
echo "  tail -f $RAG_LOGS_DIR/minio.log"
echo "  tail -f $RAG_LOGS_DIR/milvus.log"
echo ""
echo "To check instance output:"
echo "  singularity instance list"
echo ""
echo "Next: If all OK, run 03-start-rag-server.sh"
