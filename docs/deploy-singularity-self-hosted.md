<!--
  SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->
# Get Started With the NVIDIA RAG Blueprint on HPC (Singularity)

Use the following documentation to deploy the NVIDIA RAG Blueprint on HPC clusters
using [Singularity](https://sylabs.io/singularity/), with self-hosted on-premises models.
This deployment path is intended for environments where Docker is not available,
such as shared HPC clusters managed by a job scheduler (SLURM, PBS, LSF).

For the Docker Compose deployment path, refer to
[Get Started With Docker Compose](deploy-docker-self-hosted.md).

:::{tip}
All code blocks in this guide are meant to be **copied and pasted into your terminal**.
No command is meant to be run inline from this document. Each block is a self-contained
unit you can paste as-is.
:::


## Why Singularity

Docker requires a privileged daemon and root access — neither of which is typically
available on shared HPC clusters. Singularity is the standard container runtime on
HPC: it runs without root, integrates with job schedulers, and works on Lustre and
NFS filesystems.

The deployment model differs from Docker Compose in a few key ways:

- **No container daemon.** Each service is started as a regular background process
  (`singularity exec ... &`). There is no Docker Engine managing them. The scripts
  use PID files to track what is running.

- **Shared host network.** Singularity does not create virtual networks. All services
  bind directly to ports on the host (`localhost`). No port mapping is needed — the
  ports configured in the scripts are the ports you connect to.

- **SIF images.** Docker images are converted to single `.sif` files stored on disk.
  They are pulled once and reused across sessions.

- **Exec sessions.** Each startup of `01-start-infrastructure.sh` creates a timestamped
  directory (`exec_YYYY_MM_DD_N`) for logs and runtime state. Persistent data (vector
  database, object storage, model weights) lives outside this directory and survives
  across sessions.

- **`SINGULARITY_TMPDIR=/tmp`.** Singularity requires a local POSIX filesystem to
  stage GPU driver libraries and namespace structures. Using Lustre or NFS for this
  breaks GPU access (`--nv`). The scripts hardcode `/tmp`, which is always local.


## Prerequisites

1. [Get an NGC API Key](api-key.md).

2. Confirm that Singularity is installed and accessible on the compute node.

   ```bash
   singularity --version
   ```

3. Confirm that NVIDIA GPUs are available and accessible.

   ```bash
   nvidia-smi
   ```

4. Ensure Python 3.10+ is available on the host (required for the collection importer).

   ```bash
   python3 --version
   ```

5. Ensure you meet the hardware requirements.

   The GPU requirements are the same as for the Docker deployment — refer to
   [Minimum System Requirements](support-matrix.md) for the full list of supported
   configurations (H100, A100, B200, RTX PRO 6000).

   The Singularity scripts in this guide are designed and tested for a
   **4× A100 80 GB or 4× H100 80 GB** node. The LLM (Nemotron 49B) requires two
   GPUs in tensor-parallel mode (TP=2), which is why a minimum of 4 GPUs is needed
   to run the full stack simultaneously.

   | Resource | Requirement |
   |----------|-------------|
   | GPUs | 4× A100 80 GB or 4× H100 80 GB |
   | CPUs | 48 cores minimum, 64 recommended |
   | RAM | 192 GB minimum, 256 GB recommended |
   | Storage | ~200 GB free (60 GB images, 50 GB model cache, 10–50 GB runtime data) |


## Set Up the Working Directory (One-Time)

Export the NGC API Key and the working directory. All images, model caches, and
databases will be stored under `RAG_BASE_DIR`.

```bash
export NGC_API_KEY="nvapi-..."
export RAG_BASE_DIR="/path/to/rag-workdir"
```

`RAG_BASE_DIR` defaults to `$HOME/rag-test` if not set.

:::{important}
**Use a high-speed local filesystem for `RAG_BASE_DIR`.** This directory stores:
- `.sif` container images (~60 GB) — read on every service start
- Singularity image cache — read during pulls and exec
- NIM model weights (~50 GB) — streamed into GPU memory at startup

On HPC clusters, home directories are typically slow NFS mounts. Use a fast
local or parallel filesystem (NVMe scratch, GPFS, BeeGFS) to avoid significantly
longer startup times. Loading model weights from a slow filesystem can increase
NIM startup time from minutes to tens of minutes.
:::

Navigate to the Singularity deployment directory.

```bash
cd deploy/singularity
```


## Pull Images (One-Time Setup)

Pull all required Singularity images from their registries. This step takes 30–60
minutes on first run and only needs to be repeated when upgrading image versions.
Images that already exist on disk are skipped automatically.

```bash
./build-images.sh
```

You should see output similar to the following.

```output
=== NVIDIA RAG Blueprint — Image Setup ===

RAG_BASE_DIR:      /path/to/rag-workdir
Output directory:  /path/to/rag-workdir/containers/images
Singularity cache: /path/to/rag-workdir/containers/cache

✅ NGC auth configured for nvcr.io

[rag-server.sif] RAG Server v2.3.0
    Pulling from nvcr.io/nvidia/blueprint/rag-server:2.3.0...
    ✅ Pulled successfully
       Size: 8.2G
...
=== Summary ===
✅ Success: 16
❌ Failed:  0

All images ready at: /path/to/rag-workdir/containers/images

Next step: cd run && ./01-start-infrastructure.sh
```

Once complete, navigate to the run scripts directory.

```bash
cd run/
```


## Start Services

Use the following procedure to start all services. The scripts must be run **in order**
from the `deploy/singularity/run/` directory.

Re-export `NGC_API_KEY` and `RAG_BASE_DIR` if you are starting a new shell session.

```bash
export NGC_API_KEY="nvapi-..."
export RAG_BASE_DIR="/path/to/rag-workdir"
```


### 1. Start infrastructure services

Start etcd, MinIO, and Milvus. This also stops any services left over from a previous
session and creates a fresh timestamped session directory for logs and runtime state.

```bash
./01-start-infrastructure.sh
```

You should see output similar to the following.

```output
=== Cleaning up previous session ===
   No previous session found
   ✅ Cleanup done

=== New session: exec_2025_09_15_1 ===

[1/3] Starting etcd...
   ✅ etcd started (port 2379, PID 12345)
   ✅ etcd is ready (2s)
[2/3] Starting MinIO...
   ✅ MinIO started (port 9010, PID 12346)
   ✅ MinIO is ready (3s)
[3/3] Starting Milvus standalone...
   ✅ Milvus started (port 19530, PID 12347)
   ✅ Milvus is ready (45s)

=== Infrastructure Started ===
✅ etcd:   localhost:2379   (PID 12345)
✅ MinIO:  localhost:9010   (PID 12346)
✅ Milvus: localhost:19530  (PID 12347)
```


### 2. Start Redis

Start the Redis message queue used by NV-Ingest and the Ingestor Server.

```bash
./02-start-redis.sh
```

You should see output similar to the following.

```output
=== Starting Redis ===
   ✅ Redis started (port 6379, PID 12348)
   ✅ Redis is ready (1s)
```


### 3. Launch NIMs (non-blocking)

Launch all NIM microservices. This step is **non-blocking** — it starts all NIM
processes and returns immediately. NIMs are distributed across GPUs as follows:

| GPU | Services |
|-----|----------|
| GPU 0 | Embedding, Ranking, Page Elements, Graphic Elements, Table Structure, PaddleOCR |
| GPU 1 + 2 | LLM 49B (tensor parallel, TP=2) |
| GPU 3 | VLM, NV-Ingest |

```bash
./03-start-nim-models.sh
```

You should see output similar to the following.

```output
=== Launching NIM Models ===

[1/8] Embedding NIM (GPU 0, port 9080)...
   ✅ Embedding NIM started (PID 12350)
[2/8] Ranking NIM (GPU 0, port 1976)...
   ✅ Ranking NIM started (PID 12351)
[3/8] LLM NIM 49B (GPU 1+2, port 8999, TP=2)...
   ✅ LLM NIM started (PID 12352)
...
=== All 8 NIM processes launched ===
Next: Run 04-wait-nim-models.sh to wait for all NIMs to be ready.
```


### 4. Wait for NIMs to be ready

Wait for all NIMs to pass their health checks. **On first run**, NIMs download and
cache their model weights — this can take 5–30 minutes depending on model size and
available bandwidth. Subsequent starts take 2–5 minutes.

```bash
./04-wait-nim-models.sh
```

The script polls each NIM until it responds healthy, then prints a summary.

```output
=== Waiting for NIMs to be ready ===

   Service              Port    Status
   ─────────────────────────────────────
   Embedding NIM        9080    ✅ ready (42s)
   Ranking NIM          1976    ✅ ready (38s)
   LLM NIM 49B          8999    ✅ ready (8m12s)
   VLM NIM              1977    ✅ ready (3m05s)
   Page Elements        8000    ✅ ready (1m22s)
   Graphic Elements     8003    ✅ ready (1m18s)
   Table Structure      8009    ✅ ready (1m24s)
   PaddleOCR            8016    ✅ ready (1m19s)

=== All 8 NIMs ready ===
```


### 5. Start NV-Ingest

Start the NV-Ingest document processing microservice. This script **blocks** until
the internal Ray pipeline is fully initialised (2–5 minutes cold start).

```bash
./05-start-nv-ingest-ms.sh
```

You should see output similar to the following.

```output
=== Starting NV-Ingest Microservice ===

   ✅ Redis running (PID 12348)
   ✅ All prerequisite NIMs are running

Starting NV-Ingest...
   ✅ NV-Ingest process started (PID 12360)
   ⏳ Waiting for Ray pipeline to be ready...
   ✅ Ray pipeline ready (127s)

=== NV-Ingest Started ===
✅ NV-Ingest: http://localhost:7670
```


### 6. Start the Ingestor Server

Start the document ingestion API.

```bash
./06-start-ingest-server.sh
```

You can verify the ingestor server is ready by running the following.

```bash
curl -s http://localhost:8082/health
```

You should see output similar to the following.

```output
{"message":"Service is up."}
```


### 7. Start the RAG Server

Start the RAG query orchestrator, which handles all user queries by coordinating
vector search, reranking, and LLM calls.

```bash
./07-start-rag-server.sh
```

You can verify the RAG server is ready by running the following.

```bash
curl -s http://localhost:8081/health
```

You should see output similar to the following.

```output
{"message":"Service is up."}
```


### 8. Start the Frontend (optional)

Start the web UI. The frontend acts as a reverse proxy for the RAG Server and the
Ingestor Server.

```bash
./08-start-frontend.sh
```

You should see output similar to the following.

```output
=== Frontend Started ===
✅ Web UI: http://10.0.0.5:3000

Open this URL in your browser to use the RAG interface.
```

:::{note}
In Singularity (shared host network) there is no port mapping. The UI always
listens on port 3000, regardless of how Docker Compose would map it externally.
:::


## Validate the Deployment

Run the full health check to confirm all services are operational.

```bash
./09-validate-all-services.sh
```

All checks should pass.

```output
=== Validating All Services ===

Infrastructure:
   ✅ etcd        - port 2379
   ✅ MinIO       - port 9010
   ✅ Milvus      - port 19530

Redis:
   ✅ Redis       - port 6379

NIM Models:
   ✅ Embedding NIM     - HTTP 200
   ✅ Ranking NIM       - HTTP 200
   ✅ LLM NIM           - HTTP 200
   ✅ VLM NIM           - HTTP 200
   ✅ Page Elements     - HTTP 200
   ✅ Graphic Elements  - HTTP 200
   ✅ Table Structure   - HTTP 200
   ✅ PaddleOCR         - HTTP 200

Application Layer:
   ✅ NV-Ingest         - HTTP 200
   ✅ Ingestor Server   - HTTP 200
   ✅ RAG Server        - HTTP 200

Results: 15/15 checks passed
```


## Experiment with the Web User Interface

After the RAG Blueprint is deployed, open a browser and navigate to the Frontend URL
printed by `08-start-frontend.sh`. You can start uploading documents and asking
questions immediately. For details, see [User Interface for NVIDIA RAG Blueprint](user-interface.md).


## Ingest Documents

Use the collection importer in `deploy/singularity/scripts/` to bulk-import documents.
Each first-level subdirectory of the root directory becomes a separate collection.

Install the required Python packages.

```bash
pip install -r deploy/singularity/scripts/requirements.txt
```

Run a dry run first to validate file readability before uploading.

```bash
python3 deploy/singularity/scripts/ingest_collections.py \
  --root-dir /path/to/your/documents \
  --dry-run
```

Then run the full import.

```bash
python3 deploy/singularity/scripts/ingest_collections.py \
  --root-dir /path/to/your/documents
```

For the full list of options, refer to the
[Collection Importer documentation](../deploy/singularity/scripts/README.md).


## Shut Down Services

To stop all running services and free all ports.

```bash
./99-stop-all.sh
```

Everything stored under `RAG_BASE_DIR` is preserved across shutdowns:

| Path | Contents |
|------|----------|
| `$RAG_BASE_DIR/db/` | Milvus vector database, MinIO objects, etcd state |
| `$RAG_BASE_DIR/models/` | NIM model weights (no re-download on next start) |
| `$RAG_BASE_DIR/containers/images/` | `.sif` images (no re-pull on next start) |
| `$RAG_BASE_DIR/containers/cache/` | Singularity image cache |


## Advanced Deployment Considerations

### Logs

Each session writes logs to a timestamped directory under `RAG_BASE_DIR`. To find
and follow logs for a specific service.

```bash
tail -f $RAG_BASE_DIR/exec_*/logs/rag-server.log
```

```bash
tail -f $RAG_BASE_DIR/exec_*/logs/nv-ingest-ms.log
```

### Remote access via SSH tunnel

HPC compute nodes are typically not directly reachable from your laptop. Use SSH
port forwarding to tunnel services through the login node.

```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    login-node ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    compute-node
```

After the tunnel is established, access services from your laptop at:

| Service | URL |
|---------|-----|
| RAG Server API docs | `http://localhost:8081/docs` |
| Ingestor API docs | `http://localhost:8082/docs` |
| Web UI | `http://localhost:3000` |

### GPU allocation

The default layout assumes 4 GPUs (A100 40 GB or equivalent). To change GPU
assignments, edit the relevant `run/nim/nim-*.sh` script and update the
`CUDA_VISIBLE_DEVICES` variable before running `03-start-nim-models.sh`.

### Re-running without restarting NIMs

NIMs take the longest to start. If you only need to restart the application layer
(ingestor server, RAG server, frontend), run scripts 06–08 individually without
re-running scripts 03–05.

### Port conflicts

`01-start-infrastructure.sh` attempts to free all required ports at startup.
To check for conflicts manually.

```bash
lsof -i :8081
lsof -i :8082
lsof -i :3000
```


## Optional Modules Not Yet Supported

The following optional features available in the Docker Compose deployment are not
yet implemented in the Singularity deployment. They are planned for future versions.

| Module | Docker Compose | Status | Notes |
|--------|---------------|--------|-------|
| **NeMo Guardrails** | `docker-compose-nemo-guardrails.yaml` | Not supported | Requires a separate NeMo Guardrails service container; no Singularity startup script exists yet |
| **Observability** | `observability.yaml` | Not supported | Requires OTEL collector, Prometheus and Grafana containers; significant infrastructure addition |
| **NeMo Retriever OCR** | Alternative to PaddleOCR | Not supported | Requires swapping the OCR NIM; not yet wired into the NIM startup scripts |
| **MIG (Multi-Instance GPU)** | `mig-deployment.md` | Not supported | Requires GPU partitioning configuration specific to the cluster scheduler |

Feature flags that are purely env-var controlled — such as `ENABLE_QUERYREWRITER`,
`ENABLE_REFLECTION`, `ENABLE_QUERY_DECOMPOSITION`, `ENABLE_FILTER_GENERATOR`, and
`ENABLE_VLM_INFERENCE` — are already supported. Export the flag before running
`07-start-rag-server.sh` to enable them.

```bash
export ENABLE_QUERYREWRITER=True
export ENABLE_REFLECTION=true
./07-start-rag-server.sh
```


## Related Topics

- [NVIDIA RAG Blueprint Documentation](readme.md)
- [Get Started With Docker Compose](deploy-docker-self-hosted.md)
- [Collection Importer](../deploy/singularity/scripts/README.md)
- [Best Practices for Common Settings](accuracy_perf.md)
- [Troubleshoot](troubleshooting.md)
