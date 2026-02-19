#!/bin/bash
# Start all NIM groups (retrieval + ingest + VLM).
# Run after 01-start-infrastructure.sh and 03-start-redis.sh.
#
# For partial deployment, run the individual group scripts directly:
#   nim-retrieval.sh  — Embedding + Ranking + LLM   (profile: rag)
#   nim-ingest.sh     — YOLOX x3 + PaddleOCR        (profile: ingest)
#   nim-vlm.sh        — VLM                          (profile: vlm)
#
# GPU distribution (4× A100 80GB):
#   GPU 0:   Embedding + Ranking + YOLOX×3 + PaddleOCR (all small, ~10 GB)
#   GPU 1+2: LLM 49B (TP=2, needs 2 GPUs — BF16 weights ~79 GB total)
#   GPU 3:   VLM 8B
set -e

DIR="$(dirname "$0")"

bash "$DIR/nim-retrieval.sh"
echo ""
bash "$DIR/nim-ingest.sh"
echo ""
bash "$DIR/nim-vlm.sh"
echo ""
echo "=== All NIM groups launched ==="
echo "Next: bash 05-wait-nim-models.sh"
