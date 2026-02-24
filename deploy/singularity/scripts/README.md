# Singularity Deployment Scripts

Scripts for deploying the NVIDIA RAG Blueprint on HPC clusters using Singularity/Apptainer.

## Quick Start

```bash
# 1. Set required environment variables
export NGC_API_KEY='your-ngc-api-key'
export RAG_BASE_DIR='/path/to/rag-workdir'   # default: $HOME/rag-test

# 2. Build all images (one-time setup, ~30-60 min)
cd scripts/
./build-images.sh

# 3. Start the stack
./01-start-infrastructure.sh   # etcd, MinIO, Milvus
./03-start-redis.sh            # Redis message queue
./04-start-nim-models.sh       # Launch 8 NIMs (non-blocking)
./05-wait-nim-models.sh        # Wait for NIMs ready (5-10 min)
./06-start-nv-ingest-ms.sh    # NV-Ingest processor
./07-start-ingest-server.sh   # Ingestion API (port 8082)
./08-start-rag-server.sh      # RAG query API (port 8081)
./10-validate-all-services.sh # Validate everything
```

## Image Setup

### `build-images.sh`

Builds and pulls all required Singularity images:

- Images **without** a local `.def` (rag-server, ingestor-server) are pulled from NGC.
- Images **with** a local `.def` (NIMs, infrastructure) are built locally to add Singularity startscript support.
- Already-existing images are skipped automatically.

```bash
export NGC_API_KEY='your-ngc-api-key'
export RAG_BASE_DIR='/path/to/rag-workdir'

./build-images.sh
```

| Variable | Description |
|----------|-------------|
| `NGC_API_KEY` | NVIDIA NGC API key (required for NGC pulls and NIM builds) |
| `RAG_BASE_DIR` | Base working directory. Images go in `$RAG_BASE_DIR/containers/images`, cache in `$RAG_BASE_DIR/containers/cache`. Default: `$HOME/rag-test` |

## Startup Script Reference

| Script | Purpose | Dependencies | Ports |
|--------|---------|--------------|-------|
| `00-config.sh` | Shared configuration (sourced by other scripts) | — | — |
| `01-start-infrastructure.sh` | etcd, MinIO, Milvus | — | 2379, 9010, 19530 |
| `02-test-connectivity.sh` | Connectivity test (optional) | 01 | — |
| `03-start-redis.sh` | Redis message queue | — | 6379 |
| `04-start-nim-models.sh` | Launch 8 NIMs (non-blocking) | GPUs | — |
| `05-wait-nim-models.sh` | Wait for all NIMs ready | 04 | 9080, 1976, 8999, 8997, 8000–8011 |
| `06-start-nv-ingest-ms.sh` | NV-Ingest processor | 03, 05 | 7670, 7671 |
| `07-start-ingest-server.sh` | Ingestion API | 01, 03, 05, 06 | 8082 |
| `08-start-rag-server.sh` | RAG query API | 01 | 8081 |
| `09-start-frontend.sh` | Frontend UI | 08 | 3000 |
| `10-validate-all-services.sh` | Full health validation | all | — |
| `89-stop-app-layer.sh` | Stop app layer (keep infra) | — | — |
| `99-stop-all.sh` | Stop all services | — | — |

## Resource Requirements

**Minimum**: 3–4 GPUs (44 GB VRAM), 48 CPUs, 192 GB RAM
**Recommended**: 4× A100 (40 GB), 64 CPUs, 256 GB RAM

## GPU Distribution (4-GPU Layout)

Optimized layout that avoids overloading GPU 0 (Docker Compose default puts 8 services on GPU 0).

| GPU | Services | Purpose |
|-----|----------|---------|
| **GPU 0** | Embedding NIM, Ranking NIM, Milvus | Embedding & retrieval |
| **GPU 1** | LLM NIM (49B) | Text generation |
| **GPU 2** | Page Elements, Graphic Elements, Table Structure, PaddleOCR | Document processing |
| **GPU 3** | VLM NIM, NV-Ingest | Vision & ingestion |

## Remote Access

SSH tunnel from your laptop to the compute node:

```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 login-node \
    ssh -L 8081:localhost:8081 -L 8082:localhost:8082 compute-node
```

- RAG Server API: http://localhost:8081/docs
- Ingestor API:   http://localhost:8082/docs

## NIM Maintenance

```bash
./rebuild-nims.sh   # Rebuild all NIM images (after def file changes)
./rebuild-vlm.sh    # Rebuild VLM image only
```

## Troubleshooting

- Logs are in `$RAG_BASE_DIR/logs/` (current exec) or the `exec_*/logs/` subdirectory.
- NIMs not loading: check GPU memory with `nvidia-smi`.
- Port conflicts: `lsof -i :PORT`.
- Milvus auth errors: verify `region: us-east-1` in `milvus.yaml`.
