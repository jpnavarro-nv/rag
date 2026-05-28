# Singularity Deployment Scripts

Scripts for deploying the NVIDIA RAG Blueprint on HPC clusters using Singularity/Apptainer.

## Quick Start

```bash
# 1. Set required environment variables
export NGC_API_KEY='your-ngc-api-key'
export RAG_BASE_DIR='/path/to/rag-workdir'   # REQUIRED — no default

# 2. Build all images (one-time setup, ~30-60 min)
cd deploy/singularity
./build-images.sh

# 3. Start the stack
cd run/
./01-start-infrastructure.sh   # etcd, MinIO, Milvus
./02-start-redis.sh            # Redis message queue
./03-start-nim-models.sh       # Launch 8 NIMs (non-blocking)
./04-wait-nim-models.sh        # Wait for NIMs ready (5-10 min)
./05-start-nv-ingest-ms.sh    # NV-Ingest processor
./06-start-ingest-server.sh   # Ingestion API (port 8082)
./07-start-rag-server.sh      # RAG query API (port 8081)
./08-start-frontend.sh        # Web UI (port 3000)
./09-validate-all-services.sh # Validate everything
```

## Image Setup

### `build-images.sh`

Pulls all required Singularity images from their registries (NGC for NIMs and blueprints, public registries for infrastructure). Already-existing SIFs are skipped automatically.

```bash
export NGC_API_KEY='your-ngc-api-key'
export RAG_BASE_DIR='/path/to/rag-workdir'

cd deploy/singularity
./build-images.sh
```

| Variable | Description |
|----------|-------------|
| `NGC_API_KEY` | NVIDIA NGC API key (required for NGC pulls and NIM builds) |
| `RAG_BASE_DIR` | **Required.** Base working directory. Images go in `$RAG_BASE_DIR/containers/images`, cache in `$RAG_BASE_DIR/containers/cache`. No default — the scripts exit if unset. |

## Startup Script Reference

| Script | Purpose | Dependencies | Ports |
|--------|---------|--------------|-------|
| `config.sh` | Shared configuration (sourced by other scripts) | — | — |
| `01-start-infrastructure.sh` | etcd, MinIO, Milvus | — | 2379, 9010, 19530 |
| `02-start-redis.sh` | Redis message queue | — | 6379 |
| `03-start-nim-models.sh` | Launch NIMs (non-blocking) | GPUs | — |
| `04-wait-nim-models.sh` | Wait for all NIMs ready | 03 | 9080, 1976, 8999, 1977, 8000, 8003, 8009, 8016 |
| `05-start-nv-ingest-ms.sh` | NV-Ingest processor | 02, 04 | 7670, 7671 |
| `06-start-ingest-server.sh` | Ingestion API | 01, 02, 04, 05 | 8082 |
| `07-start-rag-server.sh` | RAG query API | 01 | 8081 |
| `08-start-frontend.sh` | Frontend UI | 07 | 3000 |
| `09-validate-all-services.sh` | Full health validation | all | — |
| `99-stop-all.sh` | Stop all services | — | — |
| `submit-job.sh` | Slurm batch wrapper — runs 01–09 in one job, supervises until `scancel` | Slurm | — |

## Batch Mode (Slurm)

For unattended deployment via the scheduler, use `submit-job.sh` to run 01–09
as a single Slurm batch job:

```bash
sbatch --export=ALL submit-job.sh
```

`sbatch` is **asynchronous** — it queues the job and returns immediately with
`Submitted batch job <JOBID>`. The script itself runs on the compute node when
Slurm allocates resources, and its full output (including the early banner with
the exact `tail -F` and `scancel` commands) is written to
`rag-setup-<JOBID>.log` in the directory you ran `sbatch` from.

To watch progress:

```bash
tail -F rag-setup-<JOBID>.log
```

Ctrl-C on `tail` only stops following the log — the job keeps running. To stop
the stack cleanly: `scancel <JOBID>` (triggers a graceful `99-stop-all.sh` via
the script's SIGTERM trap).

The `#SBATCH` directives in `submit-job.sh` (`--account`, `--partition`,
`--gres`, `--time`) are site-specific — edit them or override on the CLI.
See `docs/deploy-singularity-self-hosted.md` for the full reference.

## Resource Requirements

**Minimum**: 3–4 GPUs (44 GB VRAM), 48 CPUs, 192 GB RAM
**Recommended**: 4× A100 (40 GB), 64 CPUs, 256 GB RAM

## GPU Distribution (4-GPU Layout)

Optimized layout that avoids overloading GPU 0 (Docker Compose default puts 8 services on GPU 0).

| GPU | Services | Purpose |
|-----|----------|---------|
| **GPU 0** | Embedding NIM, Ranking NIM, Page Elements, Graphic Elements, Table Structure, PaddleOCR | Retrieval + document processing |
| **GPU 1+2** | LLM NIM 49B (TP=2) | Text generation |
| **GPU 3** | VLM NIM, NV-Ingest | Vision & ingestion |

## Remote Access

SSH tunnel from your laptop to the compute node:

```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 login-node \
    ssh -L 8081:localhost:8081 -L 8082:localhost:8082 compute-node
```

- RAG Server API: http://localhost:8081/docs
- Ingestor API:   http://localhost:8082/docs

## Troubleshooting

- Logs are in `$RAG_BASE_DIR/exec_YYYY_MM_DD_N/logs/`. Use `ls $RAG_BASE_DIR/exec_*/` to find the current session directory.
- NIMs not loading: check GPU memory with `nvidia-smi`.
- Port conflicts: `lsof -i :PORT`.
- Milvus auth errors: verify `region: us-east-1` in `milvus.yaml`.
