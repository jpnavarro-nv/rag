# RAG Stack Startup Scripts - Complete Guide

Complete set of scripts to deploy the NVIDIA RAG Blueprint on HPC clusters using Singularity/Apptainer.

## 📋 Overview

This deployment implements **Opção 2 (Complete Local)** - all services run locally on the compute node including infrastructure, NIMs, and ingestion pipeline.

## 🚀 Quick Start Sequence

```bash
# Full Stack (all services)
./01-start-infrastructure.sh  # etcd, MinIO, Milvus
./04-start-redis.sh           # Redis
./05-start-nim-models.sh      # 8 NIM models (5-10 min)
./06-start-nv-ingest-ms.sh    # NV-Ingest processor
./07-start-ingest-server.sh   # Ingestion API (8082)
./03-start-rag-server.sh      # Query API (8081)
./08-validate-all-services.sh # Validate all

# Query-Only (minimal)
./01-start-infrastructure.sh
./03-start-rag-server.sh
```

## 📝 Script Reference

| Script | Purpose | Dependencies | Runtime | Ports |
|--------|---------|--------------|---------|-------|
| 00-config.sh | Configuration | - | - | - |
| 01-start-infrastructure.sh | etcd, MinIO, Milvus | None | ~60s | 2379, 9010, 19530 |
| 02-test-connectivity.sh | Connectivity test | 01 | <5s | - |
| 03-start-rag-server.sh | RAG query API | 01 | ~30s | 8081 |
| 04-start-redis.sh | Redis queue | None | ~5s | 6379 |
| 05-start-nim-models.sh | 8 NIM models | GPU | 5-10min | 9080, 1976, 8999, 8997, 8000-8011 |
| 06-start-nv-ingest-ms.sh | Document processor | 04, 05 | ~60s | 7670, 7671 |
| 07-start-ingest-server.sh | Ingestion API | 01, 04, 05, 06 | ~30s | 8082 |
| 08-validate-all-services.sh | Full validation | All | ~30s | - |
| 99-stop-all.sh | Stop all | - | ~10s | - |

## 🔍 Validation Results

Expected output from `08-validate-all-services.sh`:

✅ **15 Services Operational**:
- Infrastructure: etcd, MinIO, Milvus (3)
- Redis (1)
- NIMs: Embedding, Ranking, LLM, VLM, OCR, YOLOX x3 (8)
- NV-Ingest (1)
- Applications: Ingestor, RAG Server (2)

## 🌐 Remote Access

SSH tunnel from laptop to compute node:
```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 login-node ssh -L 8081:localhost:8081 -L 8082:localhost:8082 compute-node
```

Access URLs:
- RAG Server: http://localhost:8081/docs
- Ingestor: http://localhost:8082/docs

## 📊 Resource Requirements

**Minimum**: 3-4 GPUs (44GB VRAM), 48 CPUs, 192GB RAM
**Recommended**: 4x A100 (40GB), 64 CPUs, 256GB RAM

## 🎮 GPU Configuration Strategy (Optimized for 4 GPUs)

This deployment uses an **optimized 4-GPU distribution** that improves upon Docker Compose's default (which overloads GPU 0 with 8 services).

### GPU Distribution

| GPU | Services | Load | Purpose |
|-----|----------|------|---------|
| **GPU 0** | Embedding, Ranking, Milvus | Medium (3) | **Embedding & Retrieval** |
| **GPU 1** | LLM (49B) | Heavy (1) | **LLM Generation** |
| **GPU 2** | Page/Graphic/Table YOLOX, OCR | Light (4) | **Document Processing** |
| **GPU 3** | VLM, NV-Ingest | Medium (2) | **Vision & Ingestion** |

### Services WITH GPU access (`--nv` flag):
- ✅ **Milvus** (01) - GPU 0 - Vector database GPU indexing/search
- ✅ **Embedding NIM** (05) - GPU 0 - 1B embedding model
- ✅ **Ranking NIM** (05) - GPU 0 - 1B reranking model
- ✅ **LLM NIM** (05) - GPU 1 - 49B generation model
- ✅ **VLM NIM** (05) - GPU 3 - 8B vision-language model
- ✅ **Page Elements** (05) - GPU 2 - YOLOX layout detection
- ✅ **Graphic Elements** (05) - GPU 2 - YOLOX graphics detection
- ✅ **Table Structure** (05) - GPU 2 - YOLOX table detection
- ✅ **PaddleOCR** (05) - GPU 2 - OCR model
- ✅ **NV-Ingest** (06) - GPU 3 - Ray-based document processor

### Services WITHOUT GPU (CPU-only):
- ⭕ **etcd** (01) - Coordination service
- ⭕ **MinIO** (01) - Object storage
- ⭕ **Redis** (04) - Message queue
- ⭕ **RAG Server** (03) - Orchestrator API
- ⭕ **Ingestor Server** (07) - Ingestion API

### Why This Distribution?

**Docker Default Problem**: GPU 0 gets 8 services (overloaded!)

**Our Solution**:
- ✅ Balances load across 4 GPUs (max 4 services per GPU)
- ✅ Groups related services (embed+rank+milvus, all doc processing)
- ✅ Isolates heavy LLM model on dedicated GPU
- ✅ Pairs VLM with NV-Ingest (VLM is called for image captioning)

## 🐛 Troubleshooting

Check logs: `$RAG_LOGS_DIR/` (default: `$RAG_BASE_DIR/logs/`)

Common issues:
1. NIMs not loading: Check GPU memory with `nvidia-smi`
2. Port conflicts: Use `lsof -i :PORT` to find conflicts
3. Milvus auth errors: Verify `region: us-east-1` in milvus.yaml

For details, see full README or script comments.
