<!--
  SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->
# Deploy NVIDIA RAG Blueprint with Singularity (Self-Hosted Models)

Use this documentation to deploy the [NVIDIA RAG Blueprint](readme.md) with Singularity/Apptainer for HPC environments with self-hosted on-premises models.

> **Note**: This is an alternative deployment method for environments where Docker/Kubernetes is not available or suitable (e.g., HPC clusters, shared research infrastructure).

## Overview

This deployment method converts the Docker-based RAG Blueprint to Singularity containers, suitable for:
- HPC clusters without root access
- Shared research environments
- Systems with Singularity/Apptainer instead of Docker

## Key Differences from Docker Deployment

| Aspect | Docker Compose | Singularity |
|--------|---------------|-------------|
| Orchestration | docker-compose | Custom scripts |
| Networking | Bridge network | Host or overlay |
| GPU Access | `--gpus all` | `--nv` flag |
| Root Required | Yes (daemon) | No (rootless) |
| Multi-container | Native | Manual coordination |

## Prerequisites

1. [Get an API Key](api-key.md)

2. Singularity/Apptainer 1.1.0 or later
   ```bash
   singularity --version
   # or
   apptainer --version
   ```

3. NVIDIA GPU with driver 525.60.13 or later
   ```bash
   nvidia-smi
   ```

4. Access to NGC Container Registry
   ```bash
   export NGC_API_KEY="nvapi-..."
   ```

5. Ensure you meet [the hardware requirements](./support-matrix.md)

## Quick Start

### 1. Build Singularity Images

```bash
# Navigate to deployment directory
cd deploy/singularity

# Run the build script
./scripts/build-all-images.sh
```

### 2. Configure Environment

```bash
# Copy and edit configuration
cp configs/rag.env.template configs/rag.env
nano configs/rag.env
```

### 3. Start Services

```bash
# Start all RAG services
./scripts/start-all-services.sh
```

### 4. Verify Deployment

```bash
# Check running instances
./scripts/check-status.sh
```

## Detailed Instructions

### Building Images

[TODO: Add detailed build instructions]

### Service Configuration

[TODO: Add configuration details]

### Starting Services

[TODO: Add service startup details]

### Networking Configuration

[TODO: Add networking setup]

## Troubleshooting

[TODO: Add common issues and solutions]

## Related Topics

- [Deploy with Docker (Self-Hosted Models)](deploy-docker-self-hosted.md)
- [NVIDIA RAG Blueprint Documentation](readme.md)
- [Troubleshoot](troubleshooting.md)
