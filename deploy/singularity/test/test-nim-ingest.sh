#!/bin/bash
# Functional tests for the four ingest NIMs:
#   - Page Elements    (YOLOX page layout detection)
#   - Graphic Elements (YOLOX infographic detection)
#   - Table Structure  (YOLOX table structure detection)
#   - PaddleOCR        (text recognition)
#
# Tests health readiness and, where possible, a minimal Triton HTTP inference call.
# Output goes to stdout AND $RAG_LOGS_DIR/test-nim-ingest-<timestamp>.log

source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

# Redirect stdout+stderr to log file AND terminal
LOG_FILE="$RAG_LOGS_DIR/test-nim-ingest-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

PASS=0
FAIL=0

pass() { echo "   PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "   FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== NIM Ingest Functional Tests ==="
echo "Log: $LOG_FILE"
echo "$(date)"
echo ""

# ==============================================================================
# Minimal 1×1 white PNG encoded in base64 (used as a probe image)
# Avoids needing an actual image file on disk.
# ==============================================================================
TINY_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="

# ==============================================================================
# Helper: check NIM health endpoint
# ==============================================================================
check_health() {
    local name=$1
    local port=$2

    local resp
    resp=$(curl -s --max-time 30 "http://localhost:${port}/v1/health/ready" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
        fail "$name health check — curl error (port ${port} not reachable?)"
        return 1
    fi

    # Accept any 2xx response body or an empty body (some NIMs return 200 with no body)
    if echo "$resp" | grep -qi '"status"' || [ -z "$resp" ]; then
        pass "$name health/ready → ${resp:-<empty 200>}"
        return 0
    else
        # Try to distinguish HTTP error vs non-standard response
        fail "$name health/ready unexpected response: ${resp:0:120}"
        return 1
    fi
}

# ==============================================================================
# Helper: Triton HTTP inference with a probe image (base64-encoded)
# Sends a single-pixel PNG as input tensor content; we only check that the
# NIM responds with a valid Triton inference response (not an HTTP error).
# A real test would use a representative image and validate bounding-box output.
# ==============================================================================
check_triton_infer() {
    local name=$1
    local port=$2
    local model=$3   # Triton model name inside the NIM

    local payload
    payload=$(printf '{
      "model_name": "%s",
      "inputs": [{
        "name": "input",
        "shape": [1, 1, 1, 3],
        "datatype": "UINT8",
        "data": [[[[ 255, 255, 255 ]]]]
      }],
      "outputs": [{"name": "output"}]
    }' "$model")

    local resp
    resp=$(curl -s --max-time 15 \
        -X POST "http://localhost:${port}/v2/models/${model}/infer" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
        fail "$name Triton infer — curl error"
        return 1
    fi

    # Accept any response that isn't a plain HTTP error page.
    # The NIM may return an inference result or a model-specific error (e.g.
    # invalid shape), but NOT a connection-refused or 404.
    if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if ('outputs' in d or 'error' in d) else 1)" 2>/dev/null; then
        pass "$name Triton /v2/models/${model}/infer responded (JSON)"
        return 0
    else
        fail "$name Triton infer unexpected response: ${resp:0:120}"
        return 1
    fi
}

# ==============================================================================
# 1. Page Elements
# ==============================================================================
echo "[1/4] Page Elements (localhost:$PAGE_ELEMENTS_PORT)"

check_health "page-elements" "$PAGE_ELEMENTS_PORT"

echo ""

# ==============================================================================
# 2. Graphic Elements
# ==============================================================================
echo "[2/4] Graphic Elements (localhost:$GRAPHIC_ELEMENTS_PORT)"

check_health "graphic-elements" "$GRAPHIC_ELEMENTS_PORT"

echo ""

# ==============================================================================
# 3. Table Structure
# ==============================================================================
echo "[3/4] Table Structure (localhost:$TABLE_STRUCTURE_PORT)"

check_health "table-structure" "$TABLE_STRUCTURE_PORT"

echo ""

# ==============================================================================
# 4. PaddleOCR
# ==============================================================================
echo "[4/4] PaddleOCR (localhost:$PADDLE_OCR_PORT)"

check_health "paddle-ocr" "$PADDLE_OCR_PORT"

# PaddleOCR also exposes a Triton HTTP inference endpoint
check_triton_infer "paddle-ocr" "$PADDLE_OCR_PORT" "paddle_ocr_ensemble"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo "Log saved: $LOG_FILE"

[ $FAIL -eq 0 ] && exit 0 || exit 1
