# NIM LLM Standalone — Singularity + SLURM

Deploy NVIDIA NIM LLMs on HPC clusters via Singularity and SLURM.
Each SLURM job allocates one exclusive node (4x A100 80GB) to serve one model.
Multiple users and multiple models can run concurrently without conflict.

## Requirements

- Singularity
- SLURM
- `nim-tools.sif` utility container (provides Python, huggingface-cli, requests, openai)
- NGC API key with access to NIM containers

## Quick Start

```bash
# Set required environment variables
export NGC_API_KEY="nvapi-..."
export NIM_BASE_DIR="/path/to/shared/dir"

# 1. Pull model images (one-time setup)
./build-nim-images.sh --list                        # see available models
./build-nim-images.sh nemotron-49b                  # pull one model

# 2. Submit a SLURM job
./submit-nim-job.sh nemotron-49b                    # allocates 1 full node

# 3. Monitor startup
tail -f $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out

# 4. Run inference (once "NIM READY" appears in the log)
python scripts/run_inference.py --url http://<node>:8999 "What is RAG?"

# 5. Stop when done
scancel <job_id>
```

## Model Catalog

Models are defined in `models.conf`. To add a new model, append one line — no code changes needed.

```bash
./build-nim-images.sh --list    # show available models
./submit-nim-job.sh --list      # same list
```

## Multi-User Workflow

All users share the same `NIM_BASE_DIR`. Container images and model weight caches
are shared (downloaded once). Each job gets its own isolated session directory:

```
$NIM_BASE_DIR/
├── containers/images/          # shared SIF files (read-only at runtime)
├── models/<key>-cache/         # shared model weights (downloaded once)
└── sessions/
    ├── alice/job_12345/        # Alice's job
    └── bob/job_12346/          # Bob's job (same or different model)
```

## Commands

| Script | Description |
|--------|-------------|
| `build-nim-images.sh` | Pull SIF images from NGC (`--list`, `--all`, `--force`) |
| `submit-nim-job.sh` | Submit a SLURM job to serve a model |
| `list-nims.sh` | List active NIM endpoints across the cluster |
| `scripts/run_inference.py` | Streaming inference client (`--url`, `--list`) |

### SLURM Overrides

Extra arguments to `submit-nim-job.sh` are forwarded to `sbatch`:

```bash
./submit-nim-job.sh qwen3-122b --time=48:00:00      # longer time limit
./submit-nim-job.sh nemotron-49b --partition=debug    # different partition
```

### Inference Client

```bash
# Explicit URL
python scripts/run_inference.py --url http://gpu-node-01:8999 "Hello"

# Or set via environment variable
export NIM_URL="http://gpu-node-01:8999"
python scripts/run_inference.py "Hello"

# List models on the endpoint
python scripts/run_inference.py --url http://gpu-node-01:8999 --list
```

## Monitoring

```bash
# List all active NIMs
./list-nims.sh

# List only your NIMs
./list-nims.sh --mine

# Watch job output
tail -f $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out

# Job metadata (sourceable)
source $NIM_BASE_DIR/sessions/$USER/job_<ID>/nim.env
echo $ENDPOINT
```

## Troubleshooting

**NIM dies during startup** — Check the log:
```bash
tail -50 $NIM_BASE_DIR/sessions/$USER/nim-<ID>.out
```
Common causes: insufficient GPU memory, corrupted model cache
(`rm -rf $NIM_BASE_DIR/models/<key>-cache`).

**"SIF not found"** — Build the image first:
```bash
./build-nim-images.sh <model-key>
```

**"cannot connect to NIM"** — The model is still loading. First load can take
10-60+ minutes while model weights are downloaded. Monitor with `tail -f`.

**Port conflicts** — Each job gets an exclusive node, so port 8999 is always
available. Override if needed: `LLM_PORT=9000 ./submit-nim-job.sh <model>`.
