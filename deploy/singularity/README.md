# Singularity Deployment for NVIDIA RAG Blueprint

Singularity/Apptainer deployment for the NVIDIA RAG Blueprint on HPC clusters.

The user-facing guide is at
[`docs/deploy-singularity-self-hosted.md`](../../docs/deploy-singularity-self-hosted.md).
This README is a directory reference.

## Directory Structure

- `build-images.sh` — pull all SIF images (one-time setup, login node)
- `configs/` — Milvus and other service configuration files
- `run/` — orchestration scripts (`submit.sh` wrapper + `01–09` startup sequence + `deploy-on-node.sh` job script)
- `run/clusters/` — per-cluster Slurm settings (account, partition, GPUs, walltime, `RAG_BASE_DIR`)
- `scripts/` — utility scripts (collection importer, drop collection)

## Quick Start

```bash
export NGC_API_KEY="nvapi-..."

cd deploy/singularity
./build-images.sh                # one-time, ~30-60 min, login node

cd run
./submit.sh                      # auto-detects cluster, fire-and-forget submit
```

See [`run/README.md`](run/README.md) for the script reference and
[`docs/deploy-singularity-self-hosted.md`](../../docs/deploy-singularity-self-hosted.md)
for the full guide (including how to add a new cluster conf and how to use
interactive mode for debugging).

## Image Reference

All images are pulled by `build-images.sh`. Versions are pinned at the top of that script.

### Blueprint Services (~15 GB)

| SIF | Purpose | Source |
|-----|---------|--------|
| `rag-server.sif` | RAG query orchestrator | `nvcr.io/nvidia/blueprint/rag-server:2.3.0` |
| `ingestor-server.sif` | Document ingestion API | `nvcr.io/nvidia/blueprint/ingestor-server:2.3.0` |
| `rag-frontend.sif` | Web UI | `nvcr.io/nvidia/blueprint/rag-frontend:2.3.0` |

### Language NIMs (~25 GB)

| SIF | Purpose | Source |
|-----|---------|--------|
| `nim-llm.sif` | LLM — Nemotron 49B | `nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0` |
| `nemoretriever-embedding.sif` | Text embeddings | `nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.1` |
| `nemoretriever-ranking.sif` | Reranking | `nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0` |
| `vlm.sif` | Vision-Language Model | `nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-vl-8b-v1:1.3.1` |

### Document Processing NIMs (~15 GB)

| SIF | Purpose | Source |
|-----|---------|--------|
| `nv-ingest.sif` | Document pipeline (Ray) | `nvcr.io/nvidia/nemo-microservices/nv-ingest:25.9.0` |
| `page-elements.sif` | Page layout detection | `nvcr.io/nim/nvidia/nemoretriever-page-elements-v2:1.5.0` |
| `graphic-elements.sif` | Graphics/chart extraction | `nvcr.io/nim/nvidia/nemoretriever-graphic-elements-v1:1.5.0` |
| `table-structure.sif` | Table structure extraction | `nvcr.io/nim/nvidia/nemoretriever-table-structure-v1:1.5.0` |
| `paddle.sif` | OCR | `nvcr.io/nim/baidu/paddleocr:1.5.0` |

### Infrastructure (~5 GB)

| SIF | Purpose | Source |
|-----|---------|--------|
| `milvus.sif` | Vector database | `milvusdb/milvus:v2.6.2-gpu` |
| `minio.sif` | Object storage | `minio/minio:RELEASE.2025-09-07T16-13-09Z` |
| `etcd.sif` | Key-value store (Milvus dependency) | `quay.io/coreos/etcd:v3.6.5` |
| `redis.sif` | Task queue (nv-ingest + ingestor) | `redis/redis-stack:7.2.0-v18` |

## GPU Requirements

| SIF | Min VRAM | Notes |
|-----|----------|-------|
| `nim-llm.sif` | 2× 80 GB | 49B BF16 ~79 GB, requires TP=2 across 2 GPUs |
| `vlm.sif` | 16 GB | 8B model |
| `nemoretriever-embedding.sif` | 4 GB | |
| `nemoretriever-ranking.sif` | 4 GB | |
| `page/graphic/table + paddle` | ~2 GB each | All fit on one GPU alongside embedding/ranking |
| `milvus.sif` | 2 GB | GPU-accelerated index (optional) |

## Storage Requirements

- **Images:** ~60 GB (shared across users via `containers/images/`)
- **Model cache:** ~50 GB (downloaded on first NIM start, shared via `models/`)
- **Runtime data:** ~10–50 GB per session (logs, vector DB, object storage)

**Recommended free space:** 200 GB
