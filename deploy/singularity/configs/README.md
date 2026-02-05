# Singularity Deployment Configurations

This directory contains configuration files for Singularity/Apptainer deployment.

## Files (to be added)

- `rag.env.template` - Environment variables template
- Network and service configuration files

**Note:** Milvus and MinIO configurations are handled via environment variables only, matching the docker-compose approach. No custom config files needed.

## Usage

Copy template files and customize for your environment:

```bash
cp rag.env.template rag.env
nano rag.env
```

## Status

🚧 Work in Progress - Configuration files will be added as deployment strategy is finalized.
