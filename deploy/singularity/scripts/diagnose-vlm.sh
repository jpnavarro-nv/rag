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

echo "=== 11. start_server.sh content ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" cat /opt/nim/start_server.sh 2>/dev/null >> "$OUTPUT_FILE" || \
    echo "start_server.sh not found or not readable" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 12. nim_llm_sdk port/server_port references (KEY for port fix) ===" >> "$OUTPUT_FILE"
echo "Searching for how launch.py builds --port argument..." >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" \
    grep -rn "NIM_SERVER_PORT\|NIM_HTTP_API_PORT\|api_port\|server_port\|--port\|host_port\|openai_port" \
    /opt/nim/llm/.venv/lib/python3.12/site-packages/nim_llm_sdk/ \
    2>/dev/null | grep -v ".pyc:" | grep -v "Binary" >> "$OUTPUT_FILE" || \
    echo "nim_llm_sdk not found at expected path" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 13. launch.py content ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" \
    find /opt/nim/llm -name "launch.py" 2>/dev/null | \
    xargs -I{} singularity exec "$RAG_IMAGES_DIR/vlm.sif" cat {} 2>/dev/null >> "$OUTPUT_FILE" || \
    echo "launch.py not found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "=== 14. nim_llm_sdk args.py (port argument definition) ===" >> "$OUTPUT_FILE"
singularity exec "$RAG_IMAGES_DIR/vlm.sif" \
    find /opt/nim/llm -name "args.py" 2>/dev/null | \
    xargs -I{} singularity exec "$RAG_IMAGES_DIR/vlm.sif" grep -n "port\|PORT" {} 2>/dev/null >> "$OUTPUT_FILE" || \
    echo "args.py not found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "" >> "$OUTPUT_FILE"
echo "=== Diagnosis Complete ===" >> "$OUTPUT_FILE"
echo "Output saved to: $OUTPUT_FILE" >> "$OUTPUT_FILE"

echo "Diagnosis complete!"
echo "Output file: $OUTPUT_FILE"
echo ""
echo "To view: cat $OUTPUT_FILE"
echo "To copy: cp $OUTPUT_FILE /tmp/vlm-diag-$(date +%Y%m%d-%H%M%S).txt"
