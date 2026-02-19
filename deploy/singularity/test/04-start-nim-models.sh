#!/bin/bash
# Start all NIM groups (retrieval + ingest + VLM).
# Run after 01-start-infrastructure.sh and 03-start-redis.sh.
#
# For partial deployment, run the individual group scripts directly:
#   nim-retrieval.sh  — Embedding + Ranking + LLM   (profile: rag)
#   nim-ingest.sh     — YOLOX x3 + PaddleOCR        (profile: ingest)
#   nim-vlm.sh        — VLM                          (profile: vlm)
#
# GPU distribution:
#   GPU 0: Embedding + Ranking
#   GPU 1: LLM (49B)
#   GPU 2: YOLOX x3 + PaddleOCR
#   GPU 3: VLM
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
