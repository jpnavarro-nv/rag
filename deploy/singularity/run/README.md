# Singularity Deployment Scripts

Scripts for deploying the NVIDIA RAG Blueprint on HPC clusters using
Singularity. See the full guide at
[`docs/deploy-singularity-self-hosted.md`](../../../docs/deploy-singularity-self-hosted.md)
— this README is a script reference, not a tutorial.

## Quick Start (Batch, recommended)

```bash
export NGC_API_KEY="nvapi-..."
cd deploy/singularity/run
./submit.sh
```

`./submit.sh` auto-detects the cluster from `hostname -f`, sources the matching
`clusters/*.conf`, submits the job via `sbatch`, prints a banner with the
exact `tail -F` and `scancel` commands, and exits in <1s.

Slurm output (and the per-job session dir) is written to:

```
$RAG_BASE_DIR/sessions/$USER/rag-setup-<JOBID>.out
$RAG_BASE_DIR/sessions/$USER/exec_<DATE>_<JOBID>/
```

## Quick Start (Interactive, for debugging or single-step)

```bash
export NGC_API_KEY="nvapi-..."
export RAG_BASE_DIR="/path/to/rag-workdir"    # not needed in batch (comes from conf)
cd deploy/singularity/run

./01-start-infrastructure.sh
./02-start-redis.sh
./03-start-nim-models.sh
./04-wait-nim-models.sh
./05-start-nv-ingest-ms.sh
./06-start-ingest-server.sh
./07-start-rag-server.sh
./08-start-frontend.sh
./09-validate-all-services.sh
```

## Startup Script Reference

| Script | Purpose | Dependencies | Ports |
|--------|---------|--------------|-------|
| `config.sh` | Shared configuration (sourced by other scripts) | — | — |
| `dirs.sh` | Canonical permanent path declarations (sourced by config.sh) | — | — |
| `cluster-config.sh` | Auto-detects cluster from hostname and sources `clusters/*.conf` | — | — |
| `clusters/*.conf` | Per-cluster settings (RAG_BASE_DIR, partition, account, GPUs, walltime) | — | — |
| `submit.sh` | **Login-node wrapper** — auto-detects cluster, submits the job, prints banner, exits | Slurm | — |
| `deploy-on-node.sh` | Slurm job script — runs 01–09 + supervisor (invoked by `submit.sh`) | Slurm | — |
| `01-start-infrastructure.sh` | etcd, MinIO, Milvus | — | 2379, 9010, 19530 |
| `02-start-redis.sh` | Redis message queue | — | 6379 |
| `03-start-nim-models.sh` | Launch NIMs (non-blocking) | GPUs | — |
| `04-wait-nim-models.sh` | Wait for all NIMs ready | 03 | 9080, 1976, 8999, 1977, 8000, 8003, 8016, 8009 |
| `05-start-nv-ingest-ms.sh` | NV-Ingest processor | 02, 04 | 7670, 7671 |
| `06-start-ingest-server.sh` | Ingestion API | 01, 02, 04, 05 | 8082 |
| `07-start-rag-server.sh` | RAG query API | 01, 04 | 8081 |
| `08-start-frontend.sh` | Frontend UI | 07 | 3000 |
| `09-validate-all-services.sh` | Full health validation | all | — |
| `99-stop-all.sh` | Stop all services | — | — |

## Resource Requirements

**Minimum:** 4× 80 GB GPUs (A100 80 GB or H100 80 GB), 48 CPUs, 192 GB RAM
**Recommended:** 4× A100/H100 80 GB, 64 CPUs, 256 GB RAM

The LLM 49B (BF16) requires ~79 GB total in tensor-parallel (TP=2) across two
80 GB GPUs. Smaller GPUs (40 GB A100 etc.) cannot serve the default model
without quantization.

## GPU Distribution (4-GPU Layout)

Optimized layout that avoids overloading GPU 0 (Docker Compose default puts 8 services on GPU 0).

| GPU | Services | Purpose |
|-----|----------|---------|
| **GPU 0** | Embedding NIM, Ranking NIM, Page Elements, Graphic Elements, Table Structure, PaddleOCR | Retrieval + document processing |
| **GPU 1+2** | LLM NIM 49B (TP=2) | Text generation |
| **GPU 3** | VLM NIM, NV-Ingest | Vision & ingestion |

## Remote Access

The compute node where your job runs is typically not directly reachable from
your laptop. Open an SSH tunnel through the login node:

```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    LOGIN_NODE ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    COMPUTE_NODE
```

Find `COMPUTE_NODE` with `squeue -j <JOBID> -o %N`.

- Web UI: http://localhost:3000
- RAG Server API: http://localhost:8081/docs
- Ingestor API:   http://localhost:8082/docs

## Troubleshooting

See the [main guide's Common Errors section](../../../docs/deploy-singularity-self-hosted.md#common-errors-and-troubleshooting)
for the full list. Quick pointers:

- Logs are in `$RAG_BASE_DIR/sessions/$USER/exec_*/logs/`. Interactive sessions
  are numbered `_N`; batch sessions include the Slurm `_<JOBID>`.
- NIMs not loading: check GPU memory with `nvidia-smi`.
- Port conflicts: `lsof -i :PORT`.
- Wrong cluster auto-detected: override with `CLUSTER_NAME=<name> ./submit.sh`.
- Milvus auth errors: verify `region: us-east-1` in `configs/milvus.yaml`.
