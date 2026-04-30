# LLM Standalone — Singularity + SLURM

Stand up fast inference servers on HPC infrastructure, with Singularity as the
container runtime and SLURM as the scheduler. Each SLURM job serves one model
on one exclusive node; multiple users and multiple models run concurrently
without conflict.

Backends:

- **vLLM** (today) — accelerated, OpenAI-compatible serving from a single
  pinned vLLM SIF (`vllm-openai-0.17.0.sif`) shared across all models.
- **NVIDIA NIM** (planned) — selectable per model via `models.conf`.

Cluster is auto-detected from hostname (Gaia A100, LNCC H100). See
`clusters/*.conf` for per-cluster settings.

## Requirements

- Singularity, SLURM
- `llm-tools.sif` utility container (built once via `./build-tools-image.sh`)

## Quick Start

```bash
# One-time setup per cluster
./build-tools-image.sh                          # utility container
./build-llm-images.sh nemotron3-120b            # vLLM SIF
./download-llm-model.sh nemotron3-120b          # HF weights

# Submit and use
./submit-llm-job.sh nemotron3-120b              # 1 job = 1 node
./list-llms.sh                                  # find your endpoint
python scripts/run_inference.py --url http://<node>:8000 "Hello"

# Stop
scancel <job_id>
```

`./build-llm-images.sh --list` shows available models.

## Cluster Auto-Detection

| Cluster | GPU | Partition | Account | Time | Base Dir |
|---|---|---|---|---|---|
| Gaia | 4× A100 80GB | gpu | llm-tic | 8h | /gaia/finetune-llm/nims/runtime |
| LNCC | 4× H100 | petrobr-h100 | lm_manutencao | 24h | /petrobr/lm_manutencao/jpnavarro/runtime |

Override base dir with `LLM_BASE_DIR=...`. Force cluster on unrecognized
hosts with `CLUSTER_NAME=lncc` (or `gaia`).

## Models

Defined in `models.conf` — one line per model, no code change to add. All
vLLM models share a single SIF.

```bash
./build-llm-images.sh --list      # available models
./submit-llm-job.sh --list        # same list
```

## Shared Storage Layout

```
$LLM_BASE_DIR/
├── containers/images/             # SIFs (read-only at runtime)
├── models/<key>-hf/               # HF weights (downloaded once, shared)
└── sessions/<user>/job_<id>/
    ├── llm.env                    # sourceable: NODE, PORT, ENDPOINT, ...
    ├── llm.log                    # vLLM stdout/stderr
    └── llm.pid
```

## Commands

| Script | Purpose |
|---|---|
| `build-llm-images.sh` | Pull vLLM SIF (`--list`, `--all`, `--force`) |
| `build-tools-image.sh` | Pull utility container |
| `download-llm-model.sh` | Pre-download HF weights (`--list`) |
| `submit-llm-job.sh` | Submit SLURM job (extra args forwarded to `sbatch`) |
| `list-llms.sh` | List active endpoints (`--mine`, `--watch[=N]`) |
| `scripts/run_inference.py` | Streaming OpenAI-compatible client |
| `scripts/benchmark_models.py` | Concurrency-sweep benchmark (`--discover`) |

### SLURM Overrides

Extra arguments to `submit-llm-job.sh` are forwarded to `sbatch`:

```bash
./submit-llm-job.sh qwen3-122b --time=48:00:00
./submit-llm-job.sh nemotron3-120b --partition=debug
```

### Inference Client

```bash
python scripts/run_inference.py --url http://<node>:8000 "Hello"
export LLM_URL="http://<node>:8000" && python scripts/run_inference.py "Hello"
python scripts/run_inference.py --url http://<node>:8000 --list  # models on endpoint
```

## Benchmark

Sweeps concurrency against active endpoints. Emits JSON, optional CSV, and
an SVG chart (throughput vs concurrency).

```bash
# Quality test (50 prompts, default concurrency 1,2,5,10,50)
python3 scripts/benchmark_models.py --discover

# Saturation test (6 prompts, ramp concurrency)
python3 scripts/benchmark_models.py --discover --max-prompts 6 \
    --concurrency 1,2,4,8,16,32,64,128,256

# Explicit endpoints instead of --discover
python3 scripts/benchmark_models.py --endpoints host1:8000 host2:8000
```

Output: `out_benchmark/benchmark_<host>_<timestamp>.{json,csv,svg}`.

| Option | Default | Description |
|---|---|---|
| `--discover` | — | Auto-discover from active SLURM jobs |
| `--endpoints` | — | Explicit `HOST:PORT` list |
| `--max-prompts N` | all | Round-robin select N (recycled if concurrency > N) |
| `--concurrency` | 1,2,5,10,50 | Sweep levels |
| `--max-tokens` | 8192 | Per response |
| `--timeout` | 300 | Per request (seconds) |
| `--temperature` | 0 | Sampling |
| `--no-warmup` | off | Skip 3 warm-up requests per model |
| `--output-csv` | — | Also export CSV |

## Monitoring

```bash
./list-llms.sh                                          # all users
./list-llms.sh --mine                                   # only $USER
./list-llms.sh --watch=10                               # auto-refresh

tail -f $LLM_BASE_DIR/sessions/$USER/llm-<job_id>.out   # job stdout
source $LLM_BASE_DIR/sessions/$USER/job_<id>/llm.env    # endpoint vars
```

## Troubleshooting

- **vLLM dies during startup** → `tail -50 $LLM_BASE_DIR/sessions/$USER/llm-<id>.out`. Common: missing weights (`./download-llm-model.sh <key>`), insufficient GPU memory.
- **"SIF not found"** → `./build-llm-images.sh <key>`.
- **"cannot connect"** → still loading; first model load can take 10–60+ min.
- **Unknown cluster** → `export CLUSTER_NAME=gaia` (or `lncc`).
