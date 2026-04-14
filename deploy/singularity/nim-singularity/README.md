# LLM Standalone — Singularity + SLURM

Deploy LLMs on HPC clusters via vLLM, Singularity and SLURM.
Each SLURM job allocates one exclusive node (4x A100 80GB) to serve one model.
Multiple users and multiple models can run concurrently without conflict.

## Requirements

- Singularity
- SLURM
- `nim-tools.sif` utility container (provides Python, huggingface-cli)

## Quick Start

```bash
# Set required environment variable
export NIM_BASE_DIR="/path/to/shared/dir"

# 1. Pull container image (one-time, shared by all models)
./build-nim-images.sh --list                        # see available models
./build-nim-images.sh nemotron3-120b                # pull vLLM SIF

# 2. Download model weights (one-time per model)
./download-nim-model.sh nemotron3-120b

# 3. Submit a SLURM job
./submit-nim-job.sh nemotron3-120b                  # allocates 1 full node

# 4. Monitor startup
tail -f $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out

# 5. Run inference (once "vLLM READY" appears in the log)
python scripts/run_inference.py --url http://<node>:8000 "What is RAG?"

# 6. Stop when done
scancel <job_id>
```

## Model Catalog

Models are defined in `models.conf`. To add a new model, append one line — no code changes needed.
All models share a single vLLM container (`vllm-openai-0.17.0.sif`).

```bash
./build-nim-images.sh --list    # show available models
./submit-nim-job.sh --list      # same list
```

## Multi-User Workflow

All users share the same `NIM_BASE_DIR`. Container images and model weights
are shared (downloaded once). Each job gets its own isolated session directory:

```
$NIM_BASE_DIR/
├── containers/images/          # shared SIF files (read-only at runtime)
├── models/<key>-hf/            # shared HuggingFace model weights
└── sessions/
    ├── alice/job_12345/        # Alice's job
    └── bob/job_12346/          # Bob's job (same or different model)
```

## Commands

| Script | Description |
|--------|-------------|
| `build-nim-images.sh` | Pull vLLM SIF image (`--list`, `--all`, `--force`) |
| `build-tools-image.sh` | Pull utility container for model downloads |
| `download-nim-model.sh` | Download HuggingFace model weights (`--list`) |
| `submit-nim-job.sh` | Submit a SLURM job to serve a model |
| `list-nims.sh` | List active LLM endpoints across the cluster |
| `scripts/run_inference.py` | Streaming inference client (`--url`, `--list`) |
| `scripts/benchmark_models.py` | Benchmark with concurrency sweep (`--discover`) |

### SLURM Overrides

Extra arguments to `submit-nim-job.sh` are forwarded to `sbatch`:

```bash
./submit-nim-job.sh qwen3-122b --time=48:00:00      # longer time limit
./submit-nim-job.sh nemotron3-120b --partition=debug  # different partition
```

### Inference Client

```bash
# Explicit URL
python scripts/run_inference.py --url http://gpu-node-01:8000 "Hello"

# Or set via environment variable
export NIM_URL="http://gpu-node-01:8000"
python scripts/run_inference.py "Hello"

# List models on the endpoint
python scripts/run_inference.py --url http://gpu-node-01:8000 --list
```

## Monitoring

```bash
# List all active endpoints
./list-nims.sh

# List only your endpoints
./list-nims.sh --mine

# Watch job output
tail -f $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out

# Job metadata (sourceable)
source $NIM_BASE_DIR/sessions/$USER/job_<ID>/nim.env
echo $ENDPOINT
```

## Troubleshooting

**vLLM dies during startup** — Check the log:
```bash
tail -50 $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out
```
Common causes: insufficient GPU memory, missing model weights
(`./download-nim-model.sh <key>`).

**"SIF not found"** — Build the image first:
```bash
./build-nim-images.sh <model-key>
```

**"cannot connect"** — The model is still loading. First load can take
10-60+ minutes while model weights are loaded. Monitor with `tail -f`.

**Port conflicts** — Each job gets an exclusive node, so port 8000 (default)
is always available. No port configuration needed.
