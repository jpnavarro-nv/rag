#!/bin/bash
# Diagnostic script for VLM NIM
OUTPUT_FILE="/tmp/vlm-diagnosis.txt"

echo "=== VLM NIM Diagnostic Report ===" > "$OUTPUT_FILE"
echo "Generated: $(date)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

source "$(dirname "$0")/00-config.sh" >> "$OUTPUT_FILE" 2>&1

echo "=== 1. Container Image Path ===" >> "$OUTPUT_FILE"
echo "$RAG_IMAGES_DIR/vlm.sif" >> "$OUTPUT_FILE"
ls -lh "$RAG_IMAGES_DIR/vlm.sif" >> "$OUTPUT_FILE" 2>&1
echo "" >> "$OUTPUT_FILE"

echo "=== 2. Environment Variables ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" env | grep -E "PATH|NIM|PYTHON" >> "$OUTPUT_FILE" 2>&1
echo "" >> "$OUTPUT_FILE"

echo "=== 3. Directory /opt/nim/ ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" ls -la /opt/nim/ >> "$OUTPUT_FILE" 2>&1
echo "" >> "$OUTPUT_FILE"

echo "=== 4. Search for startup scripts ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" find /opt/nim -maxdepth 3 -type f \( -name "*.sh" -o -name "start*" -o -name "run*" -o -name "entrypoint*" \) 2>/dev/null >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 5. Python executables ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" ls -la /opt/nim/llm/.venv/bin/ 2>/dev/null | head -20 >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 6. Container metadata/labels ===" >> "$OUTPUT_FILE"
singularity inspect "$RAG_IMAGES_DIR/vlm.sif" >> "$OUTPUT_FILE" 2>&1
echo "" >> "$OUTPUT_FILE"

echo "=== 7. Look for nimble or service files ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" find /opt/nim /usr/local -maxdepth 3 -type f -name "*service*" -o -name "*nimble*" 2>/dev/null >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 8. Check /usr/local/bin ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" ls -la /usr/local/bin/ 2>/dev/null >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 9. Process list (if instance running) ===" >> "$OUTPUT_FILE"
if singularity instance list | grep -q "nim-vlm-test"; then
    singularity exec instance://nim-vlm-test ps aux >> "$OUTPUT_FILE" 2>&1
else
    echo "Instance nim-vlm-test not running" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

echo "=== 10. NGC API Key status ===" >> "$OUTPUT_FILE"
if [ -n "$NGC_API_KEY" ]; then
    echo "NGC_API_KEY is set (${NGC_API_KEY:0:10}...)" >> "$OUTPUT_FILE"
else
    echo "NGC_API_KEY is NOT set" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

echo "" >> "$OUTPUT_FILE"
echo "=== Diagnosis Complete ===" >> "$OUTPUT_FILE"
echo "Output saved to: $OUTPUT_FILE" >> "$OUTPUT_FILE"

echo "Diagnosis complete!"
echo "Output file: $OUTPUT_FILE"
echo ""
echo "To view: cat $OUTPUT_FILE"
echo "To copy: cp $OUTPUT_FILE /tmp/vlm-diag-$(date +%Y%m%d-%H%M%S).txt"
