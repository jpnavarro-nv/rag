#!/bin/bash
# Wait for NIM Models to become ready - Real-Time Parallel Monitor
# Run after 04-start-nim-models.sh
#
# This script monitors all 8 NIMs simultaneously with real-time status updates.
# Models can take 5-10 minutes to load on first startup.

set -e

# Load configuration and port definitions
source "$(dirname "$0")/00-config.sh"
source "$(dirname "$0")/nim-lib.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==============================================================================
# Configuration
# ==============================================================================

# Ports sourced from nim-lib.sh (single source of truth)

# Timeouts
MAX_WAIT_TIME=600  # 10 minutes total
CHECK_INTERVAL=2   # Check every 2 seconds

# Status directory for monitor files
STATUS_DIR="$RAG_RUNTIME_DIR/nim-status"

# Clean and recreate status directory
if [ -d "$STATUS_DIR" ]; then
    rm -rf "$STATUS_DIR" 2>/dev/null || {
        echo "ERROR: Cannot remove existing status directory at $STATUS_DIR"
        echo "Try: sudo rm -rf $STATUS_DIR"
        exit 1
    }
fi

mkdir -p "$STATUS_DIR"
if [ ! -d "$STATUS_DIR" ]; then
    echo "ERROR: Failed to create status directory at $STATUS_DIR"
    exit 1
fi

chmod 755 "$STATUS_DIR"

# Test write permissions
TEST_FILE="$STATUS_DIR/.test"
if ! echo "test" > "$TEST_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to status directory at $STATUS_DIR"
    echo "Check permissions: ls -ld $STATUS_DIR"
    exit 1
fi
rm -f "$TEST_FILE"

export STATUS_DIR

# Cleanup function
cleanup_status_dir() {
    if [ -d "$STATUS_DIR" ]; then
        rm -f "$STATUS_DIR"/*.status 2>/dev/null
        rm -rf "$STATUS_DIR" 2>/dev/null
    fi
}
trap cleanup_status_dir EXIT

# ==============================================================================
# Service Definitions
# ==============================================================================

declare -A SERVICES=(
    ["embedding"]="Embedding NIM:$EMBEDDING_PORT:/v1/health/ready:GPU0"
    ["ranking"]="Ranking NIM:$RANKING_PORT:/v1/health/ready:GPU0"
    ["llm"]="LLM NIM:$LLM_PORT:/v1/health/ready:GPU1"
    ["vlm"]="VLM NIM:$VLM_PORT:/v1/health/ready:GPU3"
    ["page-elements"]="Page Elements:$PAGE_ELEMENTS_PORT:/v2/health/ready:GPU2"
    ["graphic-elements"]="Graphic Elements:$GRAPHIC_ELEMENTS_PORT:/v2/health/ready:GPU2"
    ["table-structure"]="Table Structure:$TABLE_STRUCTURE_PORT:/v2/health/ready:GPU2"
    ["paddle-ocr"]="PaddleOCR:$PADDLE_OCR_PORT:/v2/health/ready:GPU2"
)

# ==============================================================================
# Background Monitor Function (runs in parallel for each service)
# ==============================================================================

monitor_service() {
    # Disable exit-on-error for this function
    set +e

    local key=$1
    local info=${SERVICES[$key]}
    IFS=':' read -r name port endpoint gpu <<< "$info"

    local status_file="$STATUS_DIR/$key.status"
    local start_time=$(date +%s)

    # Verify status directory exists
    if [ ! -d "$STATUS_DIR" ]; then
        return 1
    fi

    # Initial status
    if ! echo "waiting:0" > "$status_file" 2>/dev/null; then
        return 1
    fi

    while true; do
        local elapsed=$(($(date +%s) - start_time))

        # Check if timeout
        if [ $elapsed -ge $MAX_WAIT_TIME ]; then
            echo "timeout:$elapsed" > "$status_file" 2>/dev/null || return 1
            break
        fi

        # Check health (suppress curl errors only)
        if curl -s -f "http://localhost:${port}${endpoint}" >/dev/null 2>&1; then
            echo "ready:$elapsed" > "$status_file" 2>/dev/null || return 1
            break
        else
            # Try to write status, if fails silently exit
            echo "loading:$elapsed" > "$status_file" 2>/dev/null || return 1
        fi

        sleep $CHECK_INTERVAL
    done
}

# ==============================================================================
# Display Function
# ==============================================================================

draw_dashboard() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         NIM Models - Real-Time Status Monitor                     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local total_elapsed=$(($(date +%s) - $START_TIME))

    # Language Models Section
    echo -e "${CYAN}Language Models (GPU 0, 1, 3):${NC}"
    draw_service_line "embedding"
    draw_service_line "ranking"
    draw_service_line "llm"
    draw_service_line "vlm"

    echo ""

    # Document Processing Section
    echo -e "${CYAN}Document Processing Models (GPU 2):${NC}"
    draw_service_line "page-elements"
    draw_service_line "graphic-elements"
    draw_service_line "table-structure"
    draw_service_line "paddle-ocr"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"

    # Calculate summary
    local ready_count=0
    local timeout_count=0
    for key in "${!SERVICES[@]}"; do
        local status_file="$STATUS_DIR/$key.status"
        if [ -f "$status_file" ]; then
            local status=$(cat "$status_file" | cut -d: -f1)
            if [ "$status" = "ready" ]; then
                ready_count=$((ready_count + 1))
            elif [ "$status" = "timeout" ]; then
                timeout_count=$((timeout_count + 1))
            fi
        fi
    done

    echo -e "Progress: ${GREEN}${ready_count}/8 Ready${NC} | Elapsed: ${total_elapsed}s | Max wait: ${MAX_WAIT_TIME}s"

    if [ $timeout_count -gt 0 ]; then
        echo -e "${RED}Timeouts: ${timeout_count}${NC}"
    fi

    echo ""
}

draw_service_line() {
    local key=$1
    local info=${SERVICES[$key]}
    IFS=':' read -r name port endpoint gpu <<< "$info"

    local status_file="$STATUS_DIR/$key.status"
    if [ ! -f "$status_file" ] || [ ! -r "$status_file" ]; then
        echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Initializing..."
        return
    fi

    # Read status safely
    local status=""
    local elapsed=0
    if [ -s "$status_file" ]; then
        IFS=':' read -r status elapsed < "$status_file" 2>/dev/null || {
            echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Initializing..."
            return
        }
    else
        echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Initializing..."
        return
    fi

    case $status in
        ready)
            echo -e "  [${GREEN}✅${NC}] $(printf '%-20s' "$name") (port $port)  ${GREEN}Ready in ${elapsed}s${NC}"
            ;;
        timeout)
            echo -e "  [${RED}❌${NC}] $(printf '%-20s' "$name") (port $port)  ${RED}Timeout after ${elapsed}s${NC}"
            ;;
        loading)
            echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Loading... ${elapsed}s"
            ;;
        waiting)
            echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Waiting..."
            ;;
        *)
            echo -e "  [${YELLOW}⏳${NC}] $(printf '%-20s' "$name") (port $port)  Unknown status"
            ;;
    esac
}

# ==============================================================================
# Main
# ==============================================================================

echo ""
echo -e "${BLUE}Starting parallel monitoring of all 8 NIMs...${NC}"
echo "This may take 5-10 minutes on first startup while models load..."
sleep 2

START_TIME=$(date +%s)

# Start background monitors for all services
for key in "${!SERVICES[@]}"; do
    monitor_service "$key" &
done

# Main display loop
while true; do
    draw_dashboard

    # Check if all services are done (ready or timeout)
    all_done=true
    for key in "${!SERVICES[@]}"; do
        status_file="$STATUS_DIR/$key.status"
        if [ -f "$status_file" ]; then
            status=$(cat "$status_file" | cut -d: -f1)
            if [ "$status" != "ready" ] && [ "$status" != "timeout" ]; then
                all_done=false
                break
            fi
        else
            all_done=false
            break
        fi
    done

    if [ "$all_done" = true ]; then
        break
    fi

    sleep 2
done

# Wait for all background jobs to complete
wait

# Final dashboard
draw_dashboard

# ==============================================================================
# Summary
# ==============================================================================
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Calculate final results
READY_COUNT=0
FAILED_COUNT=0
for key in "${!SERVICES[@]}"; do
    status_file="$STATUS_DIR/$key.status"
    status=$(cat "$status_file" | cut -d: -f1)
    if [ "$status" = "ready" ]; then
        READY_COUNT=$((READY_COUNT + 1))
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

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
    echo "  • Check PIDs: ls $RAG_RUNTIME_DIR/pids/"
    echo "  • GPU memory: nvidia-smi"
    echo ""
    echo "Common issues:"
    echo "  • Insufficient GPU memory (check nvidia-smi)"
    echo "  • NGC_API_KEY not set or invalid"
    echo "  • Model cache issues (check disk space)"
    exit 1
fi
