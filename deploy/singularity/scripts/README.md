# Singularity Deployment Scripts

This directory contains scripts for managing Singularity deployment of NVIDIA RAG Blueprint.

## Scripts

### Image Management
- `build-custom-images.sh` - Build custom images with Singularity startscripts (required for infrastructure services)
- `pull-all-images.sh` - Pull all required container images (local testing only)
- `pull-minimal-images.sh` - Pull minimal set of images for testing (local testing only)
- `update-images.sh` - Update existing images to latest versions (to be added)

### Service Orchestration
- `start-all-services.sh` - Start all RAG services
- `stop-all-services.sh` - Stop all running services
- `restart-service.sh` - Restart specific service
- `check-status.sh` - Check status of all services

### Management
- `setup-networking.sh` - Configure container networking
- `cleanup.sh` - Clean up stopped instances and temporary files
- `backup.sh` - Backup vector database and configurations

## Usage

All scripts should be executed from this directory:

```bash
cd deploy/singularity/scripts
./script-name.sh
```

## Environment Variables

Scripts expect these environment variables:
- `RAG_IMAGES_DIR` - Directory containing .sif images
- `APPTAINER_CACHEDIR` - Cache directory for builds
- `NGC_API_KEY` - NVIDIA NGC API key

## Status

🚧 Work in Progress - Scripts are being developed and tested incrementally.
