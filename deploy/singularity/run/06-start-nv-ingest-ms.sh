#!/bin/bash
# Start NV-Ingest Microservice Runtime
# Run after 03-start-redis.sh and 05-wait-nim-models.sh
#
# NV-Ingest uses Ray for parallel document processing. Startup blocks until the
# Ray pipeline is ready (not just HTTP) — expect 2–5 min cold start.

set -e

# Load configuration
source "$(dirname "$0")/config.sh"

# ==============================================================================
# Configuration
# ==============================================================================

NVINGEST_PORT=${NVINGEST_PORT:-7670}
NVINGEST_BROKER_PORT=${NVINGEST_BROKER_PORT:-7671}
NVINGEST_HOST=${NVINGEST_HOST:-localhost}
# GPU 3: Vision & Ingestion (paired with VLM which NV-Ingest calls for captioning)
NVINGEST_GPU_ID=${NVINGEST_GPU_ID:-3}

# Redis configuration
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}

# NIM endpoints (from previous script)
EMBEDDING_PORT=${EMBEDDING_PORT:-9080}
VLM_PORT=${VLM_PORT:-1977}
PAGE_ELEMENTS_PORT=${PAGE_ELEMENTS_PORT:-8000}
GRAPHIC_ELEMENTS_PORT=${GRAPHIC_ELEMENTS_PORT:-8003}
TABLE_STRUCTURE_PORT=${TABLE_STRUCTURE_PORT:-8016}
PADDLE_OCR_PORT=${PADDLE_OCR_PORT:-8009}

# ==============================================================================
# Healthcheck Functions
# ==============================================================================

wait_for_nvingest() {
    local host=$1
    local port=$2
    local attempt=1

    echo "   ⏳ Waiting for NV-Ingest to be ready (cold start may take several minutes)..."
    while true; do
        if curl -s "http://${host}:${port}/v1/health/ready" > /dev/null 2>&1; then
            echo "   ✅ NV-Ingest HTTP ready (after $((attempt * 2))s)"
            return 0
        fi
        # Bail out if the process died while we were waiting
        if [ -f "$RAG_RUNTIME_DIR/pids/nv-ingest.pid" ]; then
            local pid
            pid=$(cat "$RAG_RUNTIME_DIR/pids/nv-ingest.pid")
            if ! ps -p "$pid" > /dev/null 2>&1; then
                echo "   ❌ NV-Ingest process died while waiting (PID $pid)"
                return 1
            fi
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
}

# Verify that the Ray pipeline inside nv-ingest is truly ready to process jobs.
#
# The HTTP health endpoint (/v1/health/ready) returns 200 as soon as gunicorn
# is up — BEFORE Ray's GCS and pipeline actors finish initialising.
#
# UUID generation in nv-ingest (/v1/submit_job) is derived exclusively from the
# OpenTelemetry trace_id: job_id = trace_id_to_uuid(span.get_span_context().trace_id)
# There is no fallback to uuid4().  When OTEL_SDK_DISABLED=true the SDK returns
# INVALID_SPAN_CONTEXT (trace_id=0) → null UUID "00000000-...-000000000000" for
# EVERY job submission regardless of Ray state.  With null UUIDs all concurrent
# jobs collide on the same Redis result slot → race condition → 0 elements →
# add_metadata() iloc[0] IndexError (B2).
#
# Fix: use OTEL_TRACES/METRICS/LOGS_EXPORTER=none instead of OTEL_SDK_DISABLED.
# The SDK stays active (real per-request trace_ids), exports are suppressed
# (no connection errors in logs).  Each job now gets a unique UUID; jobs
# submitted before Ray is ready queue in Redis and are processed when Ray comes
# up — no IndexError, just a wait bounded by POLL_TIMEOUT_S (6 h).
#
# Strategy: submit a minimal probe job; if the returned task_id is a real UUID,
# gunicorn is accepting jobs (Ray may still be warming up but jobs will queue
# correctly).  If the probe endpoint rejects our payload format, fall back to
# checking the Ray dashboard port (8265) and sleeping 300 s for actor init.
wait_for_nvingest_ray() {
    local host=$1
    local port=$2
    local attempt=0
    local max_wait=600   # 10 min — abort if GCS crashed permanently
    local start_time=$SECONDS
    local NULL_UUID="00000000-0000-0000-0000-000000000000"
    local PROBE='{"payload":[],"tasks":[]}'
    local probe_errors=0
    local use_dashboard=false
    # Declare outside the loop so values are always explicitly reset each iteration
    local http_response="" response="" http_code="" job_id=""

    echo "   ⏳ Waiting for NV-Ingest Ray pipeline (not just HTTP) to be ready..."
    while true; do
        attempt=$((attempt + 1))
        # Explicit reset every iteration — `local` inside the loop would be a no-op
        # for already-declared local variables, leaving stale values on curl/python3 failures.
        http_response=""
        response=""
        http_code=""
        job_id=""

        # Bail out first if the nv-ingest process itself died — most specific cause
        if [ -f "$RAG_RUNTIME_DIR/pids/nv-ingest.pid" ]; then
            local pid
            pid=$(cat "$RAG_RUNTIME_DIR/pids/nv-ingest.pid")
            if ! ps -p "$pid" > /dev/null 2>&1; then
                echo "   ❌ NV-Ingest process died while waiting for Ray"
                return 1
            fi
        fi

        if ! $use_dashboard; then
            # Primary probe: POST a minimal job — real UUID means Ray is processing.
            # nv-ingest returns a bare JSON string (the UUID), NOT a JSON object.
            # Capture HTTP status code separately to distinguish:
            #   • 4xx   → payload format rejected by this nv-ingest version
            #   • 200 + null UUID  → Ray not yet ready (sync/fallback mode)
            #   • 200 + real UUID  → Ray pipeline fully initialised
            http_response=$(curl -s -w '\n%{http_code}' -X POST \
                -H "Content-Type: application/json" \
                -d "$PROBE" \
                --connect-timeout 5 \
                "http://${host}:${port}/v1/submit_job" 2>/dev/null) || http_response=""

            # Last line written by -w is the status code; everything before is the body.
            http_code=$(printf '%s\n' "$http_response" | tail -n 1)
            response=$(printf '%s\n' "$http_response" | head -n -1)

            # Parse UUID from response.  nv-ingest returns a bare JSON string
            # (e.g. "97eba8bf-01ef-4bd1-9dd0-876ab3e5dea5"), not {"task_id":"..."}.
            # A UUID regex guards against treating error messages as valid UUIDs.
            job_id=$(printf '%s' "$response" | python3 -c "
import sys, json, re
UUID_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)
try:
    d = json.load(sys.stdin)
    if isinstance(d, str):
        jid = d.strip()
    elif isinstance(d, dict):
        jid = d.get('task_id') or d.get('job_id') or d.get('id') or ''
    else:
        jid = ''
    jid = jid if UUID_RE.match(str(jid)) else ''
    print(str(jid).strip())
except Exception:
    print('')" 2>/dev/null) || job_id=""

            if [ -n "$job_id" ] && \
               [ "$job_id" != "null" ] && \
               [ "$job_id" != "None" ] && \
               [ "$job_id" != "$NULL_UUID" ]; then
                echo "   ✅ NV-Ingest Ray pipeline ready (submit_job probe, attempt $attempt, http=$http_code)"
                return 0
            fi

            # If job_id is empty the response was not a UUID at all.
            # This happens when the API returns a 4xx error (payload format rejected)
            # or an unexpected response body.  After 3 consecutive non-UUID responses
            # fall back to the Ray dashboard port probe.
            # A null UUID means the format IS accepted — Ray is initialising — so
            # we reset the error counter and keep waiting.
            if [ -z "$job_id" ]; then
                probe_errors=$((probe_errors + 1))
                if [ "$attempt" -eq 1 ] || [ $((attempt % 3)) -eq 0 ]; then
                    echo "   ⏳ submit_job probe: http=$http_code body='${response:0:60}' — attempt $attempt"
                fi
                if [ $probe_errors -ge 3 ]; then
                    echo "   ⚠️  submit_job probe inconclusive (non-UUID response, http=${http_code}) — switching to Ray dashboard probe"
                    use_dashboard=true
                fi
            else
                probe_errors=0  # null-UUID response confirms probe format is correct
                if [ $((attempt % 6)) -eq 0 ]; then
                    echo "   ⏳ Ray not ready yet (attempt $attempt, uuid=null, http=$http_code) — waiting 10s..."
                fi
            fi
        else
            # Fallback: Ray dashboard port 8265 is served by the GCS process.
            # When it accepts TCP connections, Ray GCS is running.
            # IMPORTANT: GCS starting does NOT mean pipeline actors are ready yet.
            # In the test run (exec_2026_02_23_1) GCS was detected and only 30 s
            # were waited — Ray actors were still initialising and null UUIDs were
            # returned for the next 6+ minutes, causing B2 IndexError on SEP/SEISCOPE.
            # Use 300 s (5 min) to give actors time to fully initialise after GCS.
            if nc -z localhost 8265 > /dev/null 2>&1; then
                echo "   ✅ NV-Ingest Ray GCS started (dashboard probe, attempt $attempt)"
                echo "      ⚠️  submit_job probe was inconclusive — waiting 300s for Ray actors..."
                sleep 300
                return 0
            fi
        fi

        # Timeout guard — if GCS crashed permanently the probe loops forever otherwise.
        # Checked after the PID guard above so the more specific message appears first.
        if [ $((SECONDS - start_time)) -gt $max_wait ]; then
            echo "   ❌ NV-Ingest Ray pipeline not ready after ${max_wait}s"
            echo "      Ray may have crashed — check:"
            echo "      grep -i 'GCS\\|Failed to connect\\|killed' $RAG_LOGS_DIR/nv-ingest.log"
            return 1
        fi

        if ! $use_dashboard; then
            if [ $((attempt % 6)) -eq 0 ]; then
                echo "   ⏳ Waiting for Ray pipeline (attempt $attempt) — waiting 10s..."
            fi
        else
            if [ $attempt -eq 1 ] || [ $((attempt % 6)) -eq 0 ]; then
                echo "   ⏳ Waiting for Ray GCS (attempt $attempt) — waiting 10s..."
            fi
        fi
        sleep 10
    done
}

# ==============================================================================
# Prerequisite Checks
# ==============================================================================

check_prerequisite() {
    local service=$1
    local host=$2
    local port=$3

    if ! nc -z $host $port > /dev/null 2>&1; then
        echo "   ❌ $service not reachable at $host:$port"
        return 1
    fi
    echo "   ✅ $service ready at $host:$port"
    return 0
}

echo "=== Starting NV-Ingest Microservice ==="
echo ""

# Check NGC_API_KEY
if [ -z "$NGC_API_KEY" ]; then
    echo "❌ Error: NGC_API_KEY not set"
    exit 1
fi

echo "Checking prerequisites..."
MISSING_PREREQS=0

check_prerequisite "Redis" $REDIS_HOST $REDIS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "PaddleOCR" localhost $PADDLE_OCR_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))
check_prerequisite "Page Elements" localhost $PAGE_ELEMENTS_PORT || MISSING_PREREQS=$((MISSING_PREREQS + 1))

if [ $MISSING_PREREQS -gt 0 ]; then
    echo ""
    echo "❌ Missing $MISSING_PREREQS prerequisite(s)"
    echo "   Run the previous scripts first:"
    echo "   - 03-start-redis.sh"
    echo "   - 04-start-nim-models.sh + 05-wait-nim-models.sh"
    exit 1
fi

echo ""

# Check if already running
if [ -f $RAG_RUNTIME_DIR/pids/nv-ingest.pid ]; then
    EXISTING_PID=$(cat $RAG_RUNTIME_DIR/pids/nv-ingest.pid)
    if ps -p $EXISTING_PID > /dev/null 2>&1; then
        echo "   ⊘  NV-Ingest already running (PID $EXISTING_PID)"
        exit 0
    else
        echo "   ⚠️  Stale PID file found, starting fresh..."
        rm -f $RAG_RUNTIME_DIR/pids/nv-ingest.pid
    fi
fi

echo "Starting NV-Ingest Microservice..."

# Create data directory for NV-Ingest if needed
mkdir -p $RAG_RUNTIME_DIR/nv-ingest-data

singularity run \
  --nv \
  --env CUDA_VISIBLE_DEVICES=$NVINGEST_GPU_ID \
  --env NGC_API_KEY=$NGC_API_KEY \
  --env NVIDIA_API_KEY=$NGC_API_KEY \
  --env NVIDIA_BUILD_API_KEY=$NGC_API_KEY \
  --env MESSAGE_CLIENT_HOST=$REDIS_HOST \
  --env MESSAGE_CLIENT_PORT=$REDIS_PORT \
  --env MESSAGE_CLIENT_TYPE=redis \
  --env REDIS_MORPHEUS_TASK_QUEUE=morpheus_task_queue \
  --env OCR_HTTP_ENDPOINT="http://localhost:${PADDLE_OCR_PORT}/v1/infer" \
  --env OCR_GRPC_ENDPOINT="localhost:$((PADDLE_OCR_PORT + 1))" \
  --env OCR_INFER_PROTOCOL=grpc \
  --env OCR_MODEL_NAME=paddle \
  --env YOLOX_HTTP_ENDPOINT="http://localhost:${PAGE_ELEMENTS_PORT}/v1/infer" \
  --env YOLOX_GRPC_ENDPOINT="localhost:$((PAGE_ELEMENTS_PORT + 1))" \
  --env YOLOX_INFER_PROTOCOL=grpc \
  --env YOLOX_GRAPHIC_ELEMENTS_HTTP_ENDPOINT="http://localhost:${GRAPHIC_ELEMENTS_PORT}/v1/infer" \
  --env YOLOX_GRAPHIC_ELEMENTS_GRPC_ENDPOINT="localhost:$((GRAPHIC_ELEMENTS_PORT + 1))" \
  --env YOLOX_GRAPHIC_ELEMENTS_INFER_PROTOCOL=grpc \
  --env YOLOX_TABLE_STRUCTURE_HTTP_ENDPOINT="http://localhost:${TABLE_STRUCTURE_PORT}/v1/infer" \
  --env YOLOX_TABLE_STRUCTURE_GRPC_ENDPOINT="localhost:$((TABLE_STRUCTURE_PORT + 1))" \
  --env YOLOX_TABLE_STRUCTURE_INFER_PROTOCOL=grpc \
  --env VLM_CAPTION_ENDPOINT="http://localhost:${VLM_PORT}/v1/chat/completions" \
  --env VLM_CAPTION_MODEL_NAME="nvidia/llama-3.1-nemotron-nano-vl-8b-v1" \
  --env MAX_INGEST_PROCESS_WORKERS=${MAX_INGEST_PROCESS_WORKERS:-16} \
  --env INGEST_LOG_LEVEL=WARNING \
  --env INGEST_RAY_LOG_LEVEL=PRODUCTION \
  --env MRC_IGNORE_NUMA_CHECK=1 \
  --env READY_CHECK_ALL_COMPONENTS=True \
  --env OTEL_TRACES_EXPORTER=none \
  --env OTEL_METRICS_EXPORTER=none \
  --env OTEL_LOGS_EXPORTER=none \
  --bind $RAG_RUNTIME_DIR/nv-ingest-data:/workspace/data \
  $RAG_IMAGES_DIR/nv-ingest.sif \
  > $RAG_LOGS_DIR/nv-ingest.log 2>&1 &

NVINGEST_PID=$!
echo $NVINGEST_PID > $RAG_RUNTIME_DIR/pids/nv-ingest.pid

# Verify process started
sleep 2
if ps -p $NVINGEST_PID > /dev/null; then
    echo "   ✅ NV-Ingest process started (port $NVINGEST_PORT, PID $NVINGEST_PID)"
else
    echo "   ❌ NV-Ingest failed to start"
    echo "   Check logs: tail -50 $RAG_LOGS_DIR/nv-ingest.log"
    exit 1
fi

# Wait for NV-Ingest HTTP layer to be ready
if ! wait_for_nvingest $NVINGEST_HOST $NVINGEST_PORT; then
    echo "   Check logs: tail -100 $RAG_LOGS_DIR/nv-ingest.log"
    exit 1
fi

# Wait for the Ray pipeline inside nv-ingest to be truly ready.
# The HTTP check above passes before Ray actors finish initialising.
# Without this check, jobs get null UUIDs → 0 elements → IndexError (B2).
if ! wait_for_nvingest_ray $NVINGEST_HOST $NVINGEST_PORT; then
    echo "   Check logs: tail -100 $RAG_LOGS_DIR/nv-ingest.log"
    exit 1
fi

echo ""
echo "=== NV-Ingest Started ==="
echo "✅ NV-Ingest: $NVINGEST_HOST:$NVINGEST_PORT (PID $NVINGEST_PID)"
echo ""
echo "Logs: tail -f $RAG_LOGS_DIR/nv-ingest.log"
echo ""
echo "Next: Run 07-start-ingest-server.sh to start Ingestor Server"
