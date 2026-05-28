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
| `deploy-on-node.sh` | Slurm job script — runs 01–09 + supervisor (invoked by `submit.sh`) | Slurm | — |
| `submit.sh` | **Wrapper for `sbatch`** — auto-detects cluster, submits the job, prints banner, exits | Slurm | — |
| `cluster-config.sh` | Auto-detects cluster from hostname and sources `clusters/*.conf` | — | — |
| `clusters/*.conf` | Per-cluster settings (RAG_BASE_DIR, partition, account, GPUs, walltime) | — | — |

## Batch Mode (Slurm)

For unattended deployment via the scheduler, use the **wrapper** `submit.sh`
— it is fire-and-forget, runs on the login node, auto-detects the cluster,
and prints a banner with the exact monitoring commands:

```bash
export NGC_API_KEY="nvapi-..."
./submit.sh
```

The wrapper exits in <1s.  The Slurm output for your job lands at:

```
$RAG_BASE_DIR/sessions/$USER/rag-setup-<JOBID>.out
```

— a per-user path, so concurrent users on the same cluster never collide.
The banner shows the absolute path ready to copy.

To watch progress (start any time after submit):

```bash
tail -F $RAG_BASE_DIR/sessions/$USER/rag-setup-<JOBID>.out
```

Ctrl-C on `tail` only stops following the log — the job keeps running. To stop
the stack cleanly: `scancel <JOBID>` (triggers a graceful `99-stop-all.sh` via
the SIGTERM trap installed before 01-09 even starts).

Cluster auto-detect can be overridden with `CLUSTER_NAME=lncc ./submit.sh`.
To add a new cluster, create `clusters/<name>.conf` and add a hostname pattern
to `cluster-config.sh`. See `docs/deploy-singularity-self-hosted.md` for the
full reference, including direct `sbatch deploy-on-node.sh` invocation if you do
not want to use the wrapper.

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

- Logs are in `$RAG_BASE_DIR/sessions/$USER/exec_YYYY_MM_DD_*/logs/`. Use `ls $RAG_BASE_DIR/sessions/$USER/exec_*/` to find your sessions (interactive sessions are numbered `_N`; batch sessions include the Slurm `_<JOBID>`).
- NIMs not loading: check GPU memory with `nvidia-smi`.
- Port conflicts: `lsof -i :PORT`.
- Milvus auth errors: verify `region: us-east-1` in `milvus.yaml`.
- Wrong cluster auto-detected: override with `CLUSTER_NAME=<name> ./submit.sh`.
