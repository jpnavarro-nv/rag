# RAG Singularity Test Scripts

**⚠️ These are TEST scripts - NOT for production use**

Test scripts for validating minimal RAG Blueprint deployment with Singularity.

## Prerequisites

- All minimal images pulled (`pull-minimal-images.sh` completed)
- NGC_API_KEY exported
- Sufficient permissions on compute node

## Directory Structure

```
rag-singularity-test/
├── 00-config.sh                 # Configuration (edit this for your paths)
├── 01-start-infrastructure.sh   # Start etcd, MinIO, Milvus
├── 02-test-connectivity.sh      # Test services are responding
├── 03-start-rag-server.sh       # Start RAG server
└── 99-stop-all.sh               # Stop all services
```

## Quick Start

### 1. Edit Configuration

```bash
nano 00-config.sh
# Adjust paths if needed (defaults should work)
```

### 2. Start Infrastructure

```bash
./01-start-infrastructure.sh
```

**Expected:**
- etcd starts on port 2379
- MinIO starts on port 9010 (console 9011)
- Milvus starts on port 19530

**Check logs:**
```bash
tail -f $RAG_BASE_DIR/logs/etcd.log
tail -f $RAG_BASE_DIR/logs/minio.log
tail -f $RAG_BASE_DIR/logs/milvus.log
```

### 3. Test Connectivity

```bash
./02-test-connectivity.sh
```

**Expected:** All services responding

### 4. Start RAG Server

```bash
export NGC_API_KEY="your-key"
./03-start-rag-server.sh
```

**Expected:** RAG server starts on port 8081

### 5. Test RAG Server

```bash
# Health check
curl http://localhost:8081/health

# API docs
curl http://localhost:8081/docs
```

### 6. Stop Everything

```bash
./99-stop-all.sh
```

## Troubleshooting

### Check running instances
```bash
singularity instance list
```

### Check logs
```bash
ls -lh /gaia/nvidia/partner/rag/logs/
tail -f /gaia/nvidia/partner/rag/logs/*.log
```

### Stop individual instance
```bash
singularity instance stop <instance-name>
```

### Force stop all
```bash
singularity instance stop -a
```

## Notes

- **Uses `singularity exec` in background** instead of `singularity instance start` due to Apptainer 1.4.5 limitations with startscripts
- Process PIDs are saved in `$RAG_RUNTIME_DIR/pids/` for management
- These scripts use `localhost` networking (single node)
- For multi-node, adjust `00-config.sh` with proper hostnames
- Milvus can take 30-60s to fully start
- RAG server uses NVIDIA API catalog (cloud) for models initially
- Full local NIM deployment requires additional NIMs

## Next Steps After Validation

1. Test basic RAG query
2. Add ingestor-server
3. Add local NIMs (instead of API catalog)
4. Create production-ready orchestration
5. Commit final versions to git repo
