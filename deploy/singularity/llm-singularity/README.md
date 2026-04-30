# LLM Standalone -- Singularity + SLURM

Stand up fast inference servers on HPC infrastructure, with Singularity as
the container runtime and SLURM as the scheduler. Each SLURM job allocates
one exclusive node to serve one model; multiple users and multiple models
run concurrently without conflict.

Backends:

- **vLLM** (today) -- accelerated, OpenAI-compatible serving from a single
  pinned vLLM SIF (`vllm-openai-0.17.0.sif`) shared across all models.
- **NVIDIA NIM** (planned) -- support for NIM containers from NGC alongside
  vLLM, selectable per model via `models.conf`. Not yet implemented.

Cluster is auto-detected from hostname (Gaia A100, LNCC H100).
See `clusters/*.conf` for per-cluster settings.

## Requirements

- Singularity
- SLURM
- `llm-tools.sif` utility container (provides Python, huggingface-cli)

## Quick Start

```bash
# 1. Pull container image (one-time, shared by all models)
./build-llm-images.sh --list                        # see available models
./build-llm-images.sh nemotron3-120b                # pull vLLM SIF

# 2. Build utility container (one-time, for model downloads)
./build-tools-image.sh

# 3. Download model weights from HuggingFace (one-time per model)
./download-llm-model.sh nemotron3-120b

# 4. Submit a SLURM job
./submit-llm-job.sh nemotron3-120b                  # allocates 1 full node

# 5. Monitor startup
tail -f $LLM_BASE_DIR/sessions/$USER/llm-<ID>.out

# 6. Run inference (once "vLLM READY" appears in the log)
python scripts/run_inference.py --url http://<node>:8000 "What is RAG?"

# 7. Stop when done
scancel <job_id>
```

## Cluster Auto-Detection

The cluster is detected from hostname. No manual `export LLM_BASE_DIR` needed.

| Cluster | GPU | Partition | Account | Time Limit | Base Dir |
|---------|-----|-----------|---------|------------|----------|
| Gaia | 4x A100 80GB | gpu | llm-tic | 8h | /gaia/finetune-llm/nims/runtime |
| LNCC | 4x H100 | petrobr-h100 | lm_manutencao | 24h | /petrobr/lm_manutencao/jpnavarro/runtime |

To override: `export LLM_BASE_DIR="/custom/path"` before running any script.
To force a cluster: `export CLUSTER_NAME=lncc` on unrecognized hosts.

## Model Catalog

Models are defined in `models.conf`. To add a new model, append one line -- no
code changes needed. All models share a single vLLM container
(`vllm-openai-0.17.0.sif`).

```bash
./build-llm-images.sh --list    # show available models
./submit-llm-job.sh --list      # same list
```

## Multi-User Workflow

All users share the same `LLM_BASE_DIR`. Container images and model weights
are shared (downloaded once). Each job gets its own isolated session directory:

```
$LLM_BASE_DIR/
├── containers/images/          # shared SIF files (read-only at runtime)
├── models/<key>-hf/            # shared HuggingFace model weights
└── sessions/
    ├── alice/job_12345/        # Alice's job
    └── bob/job_12346/          # Bob's job (same or different model)
```

## Commands

| Script | Description |
|--------|-------------|
| `build-llm-images.sh` | Pull vLLM SIF image (`--list`, `--all`, `--force`) |
| `build-tools-image.sh` | Pull utility container for model downloads |
| `download-llm-model.sh` | Download HuggingFace model weights (`--list`) |
| `submit-llm-job.sh` | Submit a SLURM job to serve a model |
| `list-llms.sh` | List active LLM endpoints across the cluster |
| `scripts/run_inference.py` | Streaming inference client (`--url`, `--list`) |
| `scripts/benchmark_models.py` | Benchmark with concurrency sweep (`--discover`) |

### SLURM Overrides

Extra arguments to `submit-llm-job.sh` are forwarded to `sbatch`:

```bash
./submit-llm-job.sh qwen3-122b --time=48:00:00      # longer time limit
./submit-llm-job.sh nemotron3-120b --partition=debug  # different partition
```

### Inference Client

```bash
# Explicit URL
python scripts/run_inference.py --url http://gpu-node-01:8000 "Hello"

# Or set via environment variable
export LLM_URL="http://gpu-node-01:8000"
python scripts/run_inference.py "Hello"

# List models on the endpoint
python scripts/run_inference.py --url http://gpu-node-01:8000 --list
```

## Benchmark

The benchmark sweeps concurrency levels against all active endpoints,
producing per-model throughput (tok/s) and latency metrics. Output includes
JSON results, CSV export, and an SVG chart (throughput vs concurrency).

### Running a Benchmark

```bash
# Auto-discover all active endpoints on the cluster
python3 scripts/benchmark_models.py --discover

# Or specify endpoints explicitly
python3 scripts/benchmark_models.py --endpoints gpu-node-01:8000 gpu-node-02:8000
```

### Concurrency Levels

Default sweep: 1, 2, 5, 10, 50. Override with `--concurrency`:

```bash
# Quality test (low concurrency, all 50 prompts)
python3 scripts/benchmark_models.py --discover --concurrency 1,2,5,10,50

# Saturation test (ramp up to 256, fewer prompts for speed)
python3 scripts/benchmark_models.py --discover \
    --max-prompts 6 \
    --concurrency 1,2,4,8,16,32,64,128,256
```

### Prompt Selection

By default, all 50 prompts from `benchmark_prompts.json` are used.
Use `--max-prompts N` to select fewer (round-robin across categories).
When concurrency exceeds the number of prompts, they are recycled so
every worker always has a request.

```bash
# Use only 6 prompts (1 per category), good for saturation tests
python3 scripts/benchmark_models.py --discover --max-prompts 6

# Use all 50 prompts (default), good for quality/variance tests
python3 scripts/benchmark_models.py --discover
```

### All Options

| Option | Default | Description |
|--------|---------|-------------|
| `--discover` | -- | Auto-discover endpoints from active SLURM jobs |
| `--endpoints HOST:PORT ...` | -- | Explicit endpoint list |
| `--prompts FILE` | benchmark_prompts.json | Prompts JSON file |
| `--max-prompts N` | all | Round-robin select N prompts across categories |
| `--concurrency L1,L2,...` | 1,2,5,10,50 | Concurrency levels to sweep |
| `--max-tokens N` | 8192 | Max tokens per response |
| `--timeout N` | 300 | Per-request timeout (seconds) |
| `--temperature F` | 0 | Sampling temperature |
| `--no-warmup` | off | Skip 3 warm-up requests per model |
| `--output-json FILE` | auto | Override JSON output path |
| `--output-csv FILE` | none | Also export results as CSV |

### Output

Results are saved to `out_benchmark/` with timestamped filenames:

```
out_benchmark/
├── benchmark_<host>_<timestamp>.json    # full results with per-request data
├── benchmark_<host>_<timestamp>.csv     # summary table (if --output-csv)
└── benchmark_<host>_<timestamp>.svg     # throughput vs concurrency chart
```

### Typical Workflows

```bash
# 1. Start models (one job per model)
./submit-llm-job.sh nemotron3-120b
./submit-llm-job.sh llama31-70b

# 2. Wait for "vLLM READY" in both logs
./list-llms.sh            # check status: "ready" = good to go

# 3. Run quality benchmark (default: 50 prompts, low concurrency)
python3 scripts/benchmark_models.py --discover

# 4. Run saturation benchmark (6 prompts, high concurrency)
python3 scripts/benchmark_models.py --discover \
    --max-prompts 6 \
    --concurrency 1,2,4,8,16,32,64,128,256

# 5. Results in out_benchmark/ -- open the SVG chart
```

## Monitoring

```bash
# List all active endpoints
./list-llms.sh

# List only your endpoints
./list-llms.sh --mine

# Auto-refresh every 5s
./list-llms.sh --watch

# Watch job output
tail -f $LLM_BASE_DIR/sessions/$USER/llm-<ID>.out

# Job metadata (sourceable)
source $LLM_BASE_DIR/sessions/$USER/job_<ID>/llm.env
echo $ENDPOINT
```

## Troubleshooting

**vLLM dies during startup** -- Check the log:
```bash
tail -50 $LLM_BASE_DIR/sessions/$USER/llm-<ID>.out
```
Common causes: insufficient GPU memory, missing model weights
(`./download-llm-model.sh <key>`).

**"SIF not found"** -- Build the image first:
```bash
./build-llm-images.sh <model-key>
```

**"cannot connect"** -- The model is still loading. First load can take
10-60+ minutes while model weights are loaded. Monitor with `tail -f`.

**Port conflicts** -- Each job gets an exclusive node, so port 8000 (default)
is always available. No port configuration needed.

**Unknown cluster** -- On unrecognized hosts, set the cluster manually:
```bash
export CLUSTER_NAME=gaia    # or lncc
```
