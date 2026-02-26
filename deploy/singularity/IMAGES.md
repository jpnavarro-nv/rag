# Container Images for NVIDIA RAG Blueprint (Singularity)

This document describes all container images required for self-hosted deployment.

## Quick Start

```bash
# Set environment variables (adjust paths for your environment)
export NGC_API_KEY="your-key-here"
export RAG_BASE_DIR=/scratch/rag   # images → $RAG_BASE_DIR/containers/images

# Build/pull all images
cd deploy/singularity
./build-images.sh
```

---

## Image Categories

### Core Services (3 images, ~15 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `rag-server.sif` | Main orchestrator, handles queries, coordinates services | ~5 GB | **Required** |
| `ingestor-server.sif` | Document ingestion and processing | ~5 GB | **Required** |
| `rag-frontend.sif` | Web UI for interacting with RAG system | ~500 MB | **Required** |

**Docker sources:**
- `nvcr.io/nvidia/blueprint/rag-server:2.3.0`
- `nvcr.io/nvidia/blueprint/ingestor-server:2.3.0`
- `nvcr.io/nvidia/blueprint/rag-frontend:2.3.0`

---

### AI/ML NIMs - Primary Models (3 images, ~25 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `nim-llm.sif` | Large Language Model for response generation (Nemotron 49B) | ~20 GB | **Required** |
| `nim-embedding.sif` | Text embedding model for vector search | ~3 GB | **Required** |
| `nim-reranking.sif` | Reranking model for improving retrieval accuracy | ~3 GB | **Required** |

**Docker sources:**
- `nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0`
- `nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.1`
- `nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0`

**Note:** The LLM NIM is the largest image (~20 GB) and will take significant time to download.

---

### Document Processing NIMs (5 images, ~15 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `nv-ingest.sif` | Main document processing pipeline | ~5 GB | **Required** |
| `nemoretriever-page-elements.sif` | Extract page layout elements | ~2 GB | Recommended |
| `nemoretriever-table-structure.sif` | Extract table structures | ~2 GB | Recommended |
| `nemoretriever-graphic-elements.sif` | Extract graphics/charts | ~2 GB | Recommended |
| `paddleocr.sif` | OCR for text extraction | ~2 GB | Recommended |

**Docker sources:**
- `nvcr.io/nvidia/nemo-microservices/nv-ingest:25.9.0`
- `nvcr.io/nim/nvidia/nemoretriever-page-elements-v2:1.5.0`
- `nvcr.io/nim/nvidia/nemoretriever-table-structure-v1:1.5.0`
- `nvcr.io/nim/nvidia/nemoretriever-graphic-elements-v1:1.5.0`
- `nvcr.io/nim/baidu/paddleocr:1.5.0`

---

### Infrastructure Services (3 images, ~5 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `milvus.sif` | Vector database for embeddings | ~2 GB | **Required** |
| `minio.sif` | Object storage for multimodal content | ~500 MB | **Required** |
| `etcd.sif` | Distributed key-value store (for Milvus) | ~50 MB | **Required** |
| `redis.sif` | Cache and task queue | ~500 MB | Optional |

**Docker sources:**
- `milvusdb/milvus:v2.4.17`
- `minio/minio:RELEASE.2025-09-07T16-13-09Z`
- `quay.io/coreos/etcd:v3.6.5`
- `redis/redis-stack:7.2.0-v18`

---

### Optional NIMs (8 images, ~40 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `nemoguard-content-safety.sif` | Content moderation | ~8 GB | Optional |
| `nemoguard-topic-control.sif` | Topic filtering | ~8 GB | Optional |
| `nim-vlm.sif` | Vision-Language Model for image understanding | ~10 GB | Optional |
| `nemoretriever-vlm-embed.sif` | Multimodal embeddings | ~3 GB | Optional |
| `nemoretriever-ocr.sif` | Enhanced OCR | ~3 GB | Optional |
| `nemoretriever-parse.sif` | Document parsing | ~3 GB | Optional |
| `riva-asr.sif` | Audio transcription | ~3 GB | Optional |
| `guardrails-microservice.sif` | Guardrails orchestration | ~2 GB | Optional |

**Docker sources:** (not yet deployed — optional NIMs are not included in `build-images.sh`)

---

### Observability Services (4 images, ~2 GB total)

| Image | Purpose | Size | Priority |
|-------|---------|------|----------|
| `zipkin.sif` | Distributed tracing | ~500 MB | Optional |
| `otel-collector.sif` | OpenTelemetry collector | ~500 MB | Optional |
| `prometheus.sif` | Metrics collection | ~500 MB | Optional |
| `grafana.sif` | Visualization dashboard | ~500 MB | Optional |

---

## Deployment Strategies

### Standard Deployment
**Total: ~100 GB**
```bash
cd deploy/singularity
./build-images.sh
```

Includes:
- Core services (rag-server, ingestor-server, rag-frontend)
- Primary AI models (LLM, Embedding, Ranking, VLM)
- Document processing NIMs (page-elements, graphic-elements, table-structure, PaddleOCR)
- NV-Ingest pipeline
- Infrastructure (etcd, MinIO, Milvus)

---

## GPU Requirements by Image

| Image | Min GPU Memory | Recommended GPU |
|-------|---------------|-----------------|
| `nim-llm.sif` | 40 GB | A100 80GB, H100 |
| `nim-embedding.sif` | 4 GB | Any modern GPU |
| `nim-reranking.sif` | 4 GB | Any modern GPU |
| `nim-vlm.sif` | 10 GB | V100+, A100 |
| `nemoguard-*` | 10 GB each | V100+, A100 |
| `milvus.sif` | 2 GB (optional GPU) | Any modern GPU |

**Your setup (4x A100 80GB):** Can run all models comfortably with room for parallel processing.

---

## Storage Requirements

- **Cache directory:** ~20-30 GB (temporary during pull)
- **Images directory:** ~50-100 GB (permanent storage)
- **Runtime data:** ~10-50 GB (logs, vector DB, object storage)

**Total recommended:** 200 GB free space

---

## Next Steps

After pulling images:
1. Configure environment variables
2. Create orchestration scripts
3. Test individual containers
4. Set up networking between containers
5. Create startup/shutdown scripts

See `deploy/singularity/run/` for orchestration examples.
