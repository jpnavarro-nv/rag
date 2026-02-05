# Singularity Deployment Configurations

This directory contains configuration files for Singularity/Apptainer deployment.

## Files

- `milvus.yaml` - Milvus configuration defining component ports to avoid conflicts

**Note:** The milvus.yaml file is required to properly configure internal component ports. Without it, Milvus components will conflict on port 19530. The configuration sets:
- RootCoord: 53100
- DataCoord: 13333
- QueryCoord: 19531
- Proxy (client): 19530

MinIO configuration is handled via environment variables, matching the docker-compose approach.

## Usage

Copy template files and customize for your environment:

```bash
cp rag.env.template rag.env
nano rag.env
```

## Status

🚧 Work in Progress - Configuration files will be added as deployment strategy is finalized.
