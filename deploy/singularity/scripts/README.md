# Singularity Deployment Scripts

This directory contains scripts for managing Singularity deployment of NVIDIA RAG Blueprint.

## Scripts

### Image Management

**Main Script:**
- `setup-images.sh` - **PRIMARY SCRIPT** - Orchestrates building and pulling all required images
  - Usage: `./setup-images.sh [minimal|all]`
  - Builds infrastructure images (etcd, MinIO, Milvus) from definition files
  - Pulls pre-built images (RAG server, NIMs, frontend)
  - Provides unified progress tracking

**Helper Scripts:**
- `build-images.sh` - Build infrastructure images with custom startscripts (called by setup-images.sh)
- `pull-images.sh` - Pull pre-built images from registries (called by setup-images.sh)

### Service Orchestration
- `start-all-services.sh` - Start all RAG services
- `stop-all-services.sh` - Stop all running services
- `restart-service.sh` - Restart specific service
- `check-status.sh` - Check status of all services

### Management
- `setup-networking.sh` - Configure container networking
- `cleanup.sh` - Clean up stopped instances and temporary files
- `backup.sh` - Backup vector database and configurations

## Quick Start

### Setup All Images (Recommended)

```bash
cd deploy/singularity/scripts

# Set output directory
export RAG_IMAGES_DIR=/path/to/images

# Setup minimal image set (for testing)
./setup-images.sh minimal

# Or setup complete image set (for production)
./setup-images.sh all
```

### Manual Usage

If you need to run build or pull separately:

```bash
# Build only infrastructure images
./build-images.sh

# Pull only pre-built images
./pull-images.sh minimal  # or 'all'
```

## Environment Variables

Scripts expect these environment variables:
- `RAG_IMAGES_DIR` - Directory containing .sif images
- `APPTAINER_CACHEDIR` - Cache directory for builds
- `NGC_API_KEY` - NVIDIA NGC API key

## Status

🚧 Work in Progress - Scripts are being developed and tested incrementally.
