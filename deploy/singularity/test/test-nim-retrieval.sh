#!/bin/bash
# Functional tests for the three retrieval NIMs:
#   - Embedding  (POST /v1/embeddings   → 2048-dim vector)
#   - Ranking    (POST /v1/ranking      → relevance score)
#   - LLM        (POST /v1/chat/completions → generated text)
#
# Output goes to stdout AND $RAG_LOGS_DIR/test-nim-retrieval-<timestamp>.log

source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

# Redirect stdout+stderr to log file AND terminal
LOG_FILE="$RAG_LOGS_DIR/test-nim-retrieval-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

PASS=0
FAIL=0

pass() { echo "   PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "   FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== NIM Retrieval Functional Tests ==="
echo "Log: $LOG_FILE"
echo "$(date)"
echo ""

# ==============================================================================
# 1. Embedding
# ==============================================================================
echo "[1/3] Embedding (localhost:$EMBEDDING_PORT)"

EMBED_RESPONSE=$(curl -s --max-time 30 \
    http://localhost:$EMBEDDING_PORT/v1/embeddings \
    -H "Content-Type: application/json" \
    -d '{
        "model": "nvidia/llama-3.2-nv-embedqa-1b-v2",
        "input": "What is retrieval augmented generation?",
        "input_type": "query"
    }')

if [ -z "$EMBED_RESPONSE" ]; then
    fail "no response from embedding NIM"
else
    python3 - "$EMBED_RESPONSE" <<'PYEOF'
import sys, json
try:
    r = json.loads(sys.argv[1])
    emb = r["data"][0]["embedding"]
    dims = len(emb)
    if dims == 2048:
        print(f"   PASS  dimensions={dims}  tokens={r['usage']['total_tokens']}  first_val={emb[0]:.6f}")
        sys.exit(0)
    else:
        print(f"   FAIL  unexpected dimensions={dims} (expected 2048)")
        sys.exit(1)
except Exception as e:
    print(f"   FAIL  parse error: {e}  response={sys.argv[1][:200]}")
    sys.exit(1)
PYEOF
    if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
fi

echo ""

# ==============================================================================
# 2. Ranking
# ==============================================================================
echo "[2/3] Ranking (localhost:$RANKING_PORT)"

RANK_RESPONSE=$(curl -s --max-time 30 \
    http://localhost:$RANKING_PORT/v1/ranking \
    -H "Content-Type: application/json" \
    -d '{
        "model": "nvidia/llama-3.2-nv-rerankqa-1b-v2",
        "query": {"text": "What is RAG?"},
        "passages": [
            {"text": "RAG stands for Retrieval Augmented Generation, a technique that grounds LLM responses with retrieved documents."},
            {"text": "The Eiffel Tower is located in Paris, France."}
        ]
    }')

if [ -z "$RANK_RESPONSE" ]; then
    fail "no response from ranking NIM"
else
    python3 - "$RANK_RESPONSE" <<'PYEOF'
import sys, json
try:
    r = json.loads(sys.argv[1])
    rankings = r["rankings"]
    s0 = rankings[0]["logit"]
    s1 = rankings[1]["logit"]
    # Passage 0 (about RAG) should score higher than passage 1 (Eiffel Tower)
    order_ok = s0 > s1
    status = "PASS" if order_ok else "FAIL"
    print(f"   {status}  passage[0]={s0:.4f}  passage[1]={s1:.4f}  order_correct={order_ok}")
    sys.exit(0 if order_ok else 1)
except Exception as e:
    print(f"   FAIL  parse error: {e}  response={sys.argv[1][:200]}")
    sys.exit(1)
PYEOF
    if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
fi

echo ""

# ==============================================================================
# 3. LLM
# ==============================================================================
echo "[3/3] LLM (localhost:$LLM_PORT)"

LLM_RESPONSE=$(curl -s --max-time 60 \
    http://localhost:$LLM_PORT/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "nvidia/llama-3.3-nemotron-super-49b-v1.5",
        "messages": [{"role": "user", "content": "Reply with exactly one word: healthy"}],
        "max_tokens": 10,
        "temperature": 0
    }')

if [ -z "$LLM_RESPONSE" ]; then
    fail "no response from LLM NIM"
else
    python3 - "$LLM_RESPONSE" <<'PYEOF'
import sys, json
try:
    r = json.loads(sys.argv[1])
    text = r["choices"][0]["message"]["content"].strip()
    tokens = r["usage"]["completion_tokens"]
    print(f"   PASS  response='{text}'  completion_tokens={tokens}")
    sys.exit(0)
except Exception as e:
    print(f"   FAIL  parse error: {e}  response={sys.argv[1][:200]}")
    sys.exit(1)
PYEOF
    if [ $? -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo "Log saved: $LOG_FILE"

[ $FAIL -eq 0 ] && exit 0 || exit 1
