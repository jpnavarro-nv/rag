#!/bin/bash
# Diagnostic script for ALL NIMs startup commands
OUTPUT_FILE="/tmp/all-nims-diagnosis.txt"

source "$(dirname "$0")/00-config.sh" > /dev/null 2>&1

echo "=== ALL NIMs Startup Commands Diagnostic ===" > "$OUTPUT_FILE"
echo "Generated: $(date)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

check_nim() {
    local name=$1
    local sif="$RAG_IMAGES_DIR/$2"

    echo "========================================" >> "$OUTPUT_FILE"
    echo "NIM: $name" >> "$OUTPUT_FILE"
    echo "Image: $sif" >> "$OUTPUT_FILE"
    echo "========================================" >> "$OUTPUT_FILE"

    if [ ! -f "$sif" ]; then
        echo "❌ Image not found" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
        return
    fi

    echo "" >> "$OUTPUT_FILE"
    echo "--- Check /opt/nim/start_server.sh ---" >> "$OUTPUT_FILE"
    singularity exec "$sif" ls -la /opt/nim/start_server.sh 2>&1 >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "--- Check /opt/nim/ directory ---" >> "$OUTPUT_FILE"
    singularity exec "$sif" ls -la /opt/nim/*.sh 2>&1 >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "--- Check for tritonserver ---" >> "$OUTPUT_FILE"
    singularity exec "$sif" which tritonserver 2>&1 >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "--- Check /opt/nvidia/ ---" >> "$OUTPUT_FILE"
    singularity exec "$sif" ls -la /opt/nvidia/ 2>&1 | head -20 >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "--- Environment variables ---" >> "$OUTPUT_FILE"
    singularity exec "$sif" env | grep -E "NIM_|PATH=" | head -10 >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
}

# Language Model NIMs
check_nim "Embedding NIM" "nemoretriever-embedding.sif"
check_nim "Ranking NIM" "nemoretriever-ranking.sif"
check_nim "LLM NIM" "nim-llm.sif"
check_nim "VLM NIM" "vlm.sif"

# Document Processing NIMs (Triton-based)
check_nim "Page Elements" "page-elements.sif"
check_nim "Graphic Elements" "graphic-elements.sif"
check_nim "Table Structure" "table-structure.sif"
check_nim "PaddleOCR" "paddle.sif"

# NV-Ingest
echo "========================================" >> "$OUTPUT_FILE"
echo "NIM: NV-Ingest" >> "$OUTPUT_FILE"
echo "Image: $RAG_IMAGES_DIR/nv-ingest.sif" >> "$OUTPUT_FILE"
echo "========================================" >> "$OUTPUT_FILE"
if [ -f "$RAG_IMAGES_DIR/nv-ingest.sif" ]; then
    echo "" >> "$OUTPUT_FILE"
    echo "--- Check entrypoint ---" >> "$OUTPUT_FILE"
    singularity exec "$RAG_IMAGES_DIR/nv-ingest.sif" ls -la /workspace/ 2>&1 | head -20 >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    singularity exec "$RAG_IMAGES_DIR/nv-ingest.sif" which nv-ingest 2>&1 >> "$OUTPUT_FILE"
else
    echo "❌ Image not found" >> "$OUTPUT_FILE"
fi

echo "" >> "$OUTPUT_FILE"
echo "========================================" >> "$OUTPUT_FILE"
echo "=== Diagnosis Complete ===" >> "$OUTPUT_FILE"
echo "========================================" >> "$OUTPUT_FILE"

echo "Diagnosis complete!"
echo "Output: $OUTPUT_FILE"
echo ""
echo "View with: cat $OUTPUT_FILE"
