# Singularity Definition Files

This directory contains Singularity definition files (.def) for building custom containers.

## Purpose

Definition files are used when you need to:
- Customize existing containers
- Build containers from scratch
- Add specific dependencies or configurations
- Create optimized images for your HPC environment

## Files (to be added)

Custom definition files will be added here as needed:
- `rag-server.def` - Custom RAG server build (if needed)
- `custom-nim.def` - Custom NIM configurations
- etc.

## Usage

```bash
# Build from definition file
singularity build image.sif definition.def

# Or use remote build service
singularity build --remote image.sif definition.def
```

## Status

🚧 Work in Progress - Currently using pre-built images from NGC. Custom definitions will be added if customization is required.

## Note

For standard deployment, pre-built images from NGC are used. Definition files are only needed for advanced customization scenarios.
