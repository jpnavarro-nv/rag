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

`RAG_BASE_DIR` is **required** — there is no default. The scripts exit
immediately with an error if it is unset, so you cannot accidentally write
~100 GB of containers and model weights to a slow `$HOME` NFS mount.

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

:::{tip}
For unattended deployment on clusters with a job scheduler, you can run the entire
01–09 sequence as a single Slurm batch job — skip ahead to
[Run as a Slurm Batch Job](#run-as-a-slurm-batch-job). The interactive path below
is the same sequence step by step, useful for learning what each step does and
for debugging when something goes wrong.
:::

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


## Run as a Slurm Batch Job

For unattended deployment, the wrapper `deploy/singularity/run/submit.sh` runs
the entire 01–09 startup sequence as a single Slurm batch job and then enters
a supervisor loop that keeps the stack alive until you cancel the job. The
wrapper is **fire-and-forget**: it submits, prints a banner, and returns
control to your shell in under a second.

```bash
cd deploy/singularity/run
export NGC_API_KEY="nvapi-..."

./submit.sh
```

Output:

```output
Cluster: gaia (A100) — /gaia/finetune-llm/rag/runtime

Submitting RAG Blueprint to Slurm...
  Cluster   : gaia (A100)
  Partition : gpu
  Account   : llm-tic
  GPUs      : 4
  Walltime  : (partition default — no limit)
  Base dir  : /gaia/finetune-llm/rag/runtime
  User      : jpnavarro

======================================================
  RAG Blueprint — submitted
======================================================
  Job ID   : 12345
  Follow   : tail -F /gaia/finetune-llm/rag/runtime/sessions/jpnavarro/rag-setup-12345.out
  Status   : squeue -j 12345
  Stop     : scancel 12345
======================================================
```

`RAG_BASE_DIR`, partition, account, GPU count and walltime are auto-resolved
from the cluster config (see below). The wrapper exits in <1s; the job runs
later on a compute node when Slurm allocates resources.

### How the wrapper works

`submit.sh` runs on the login node and:

1. Validates `NGC_API_KEY` is exported (fail fast — before consuming queue time).
2. Auto-detects the cluster from `hostname -f` and sources
   `clusters/<name>.conf` (sets `RAG_BASE_DIR`, partition, account, etc.).
3. Creates `$RAG_BASE_DIR/sessions/$USER/` (chmod 700) for per-user log and
   runtime isolation.
4. Calls `sbatch --parsable` with the site-specific flags assembled from the
   cluster conf, including `--output=$RAG_BASE_DIR/sessions/$USER/rag-setup-%j.out`
   so multiple users on the same cluster do not collide.
5. Prints the early banner with `tail -F` / `squeue` / `scancel` commands
   pre-filled, and exits.

`sbatch` is **asynchronous** — it queues the job and returns at once. The
script that runs on the compute node (`deploy-on-node.sh`, invoked by the
wrapper) is what writes the actual progress to the log file. Nothing past
the wrapper's banner is printed to your login shell.

To watch progress on the compute node:

```bash
tail -F /path/from/banner/rag-setup-<JOBID>.out
```

After roughly 15–20 minutes — when all 9 startup steps complete — a second
`RAG Blueprint READY` banner appears in the log with the frontend and API URLs.

:::{tip}
Pressing **Ctrl-C** on `tail` does **not** stop the job. It only stops following
the log. The job continues running on the compute node.
:::

### Multi-tenant: log structure on shared clusters

Each user gets their own session tree under `$RAG_BASE_DIR/sessions/$USER/`:

```
$RAG_BASE_DIR/
├── containers/, db/, models/        ← shared across users (read once)
└── sessions/
    └── alice/                       ← chmod 700, private per user
        ├── rag-setup-12345.out      ← Slurm output for job 12345
        └── exec_2026_05_28_12345/   ← session dir (named after JOBID in batch)
            ├── logs/                ← per-service logs (etcd, milvus, nim-*, etc.)
            ├── runtime/pids/        ← PID files
            └── tmp/
```

The shared paths (`containers/`, `db/`, `models/`) are downloaded once and
reused by everyone. Only the session dir is per-user. Two users — or two
batch jobs from the same user — never collide on logs, PIDs, or `.current_exec`.

### Configuring your cluster

Cluster-specific values live in plain files at `deploy/singularity/run/clusters/`:

```
clusters/
├── gaia.conf      # Petrobras Gaia — A100, llm-tic account
└── lncc.conf      # LNCC Santos Dumont — H100, lm_manutencao account
```

Each conf sets `RAG_BASE_DIR`, `SLURM_PARTITION`, `SLURM_ACCOUNT`,
`SLURM_GPUS_PER_NODE`, `SLURM_TIME`, and `CLUSTER_GPU`. The wrapper picks the
right one via `hostname -f` regex. To add a new cluster:

1. Copy an existing conf to `clusters/<your-cluster>.conf`.
2. Edit the values to match your site (storage path, partition, account, etc.).
3. Add a hostname-pattern case in `cluster-config.sh`'s `_detect_cluster()` if
   your hostname does not already match one of the existing patterns.

To override the auto-detect:

```bash
CLUSTER_NAME=lncc ./submit.sh
```

To override a single sbatch flag on the CLI (extra args are forwarded):

```bash
./submit.sh --time=04:00:00 --partition=my-priority-queue
```

`SLURM_TIME` is intentionally empty by default — the wrapper omits `--time`
entirely so the partition's default/max walltime applies. Lower it via the
CLI override when running short experiments.

### Stopping the job

Use `scancel` to stop the stack cleanly:

```bash
scancel <JOBID>
```

`deploy-on-node.sh` installs a `SIGTERM`/`SIGINT` trap **before** the 01–09
sequence starts, so a `scancel` at any point — including during infrastructure
startup — runs `99-stop-all.sh` and shuts down every backgrounded service
gracefully before the Slurm cgroup is torn down.

### Direct sbatch (without the wrapper)

You can still call `deploy-on-node.sh` directly via `sbatch`, but you must supply
the cluster-specific flags yourself — the script intentionally has no
`#SBATCH --account`, `--partition`, `--gres`, `--time`, or `--output`:

```bash
sbatch --account=ACCOUNT --partition=PART --gres=gpu:4 \
       --output=/path/to/sessions/$USER/rag-setup-%j.out \
       --export=ALL deploy-on-node.sh
```

The wrapper is the recommended path because it handles all of this automatically
from the cluster conf.


## Advanced Deployment Considerations

### Logs

Each session writes logs to a per-user, timestamped directory under
`$RAG_BASE_DIR/sessions/$USER/`. To find and follow logs for a specific service:

```bash
tail -f $RAG_BASE_DIR/sessions/$USER/exec_*/logs/rag-server.log
```

```bash
tail -f $RAG_BASE_DIR/sessions/$USER/exec_*/logs/nv-ingest.log
```

In batch mode (via `submit.sh`) the exec dir is named `exec_<DATE>_<JOBID>`,
so logs for a specific job are at:

```bash
tail -f $RAG_BASE_DIR/sessions/$USER/exec_*_<JOBID>/logs/rag-server.log
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

HPC clusters often have ports already occupied by other services — MPI daemons,
scheduler agents, monitoring exporters, or other users' workloads. Because
Singularity runs on the **shared host network**, every port used by the blueprint
must be free on the compute node.

Every service port has a configurable default. To override a port, export the
corresponding variable **before** running the startup scripts.

```bash
export TABLE_STRUCTURE_PORT=8026   # change only what conflicts
./03-start-nim-models.sh
```

The full port table, with Singularity defaults:

| Variable | Default | Service |
|---|---|---|
| `ETCD_PORT` | `2379` | etcd |
| `MILVUS_PORT` | `19530` | Milvus |
| `MINIO_PORT` | `9010` | MinIO API |
| `MINIO_CONSOLE_PORT` | `9011` | MinIO Console |
| `REDIS_PORT` | `6379` | Redis |
| `NVINGEST_PORT` | `7670` | NV-Ingest HTTP |
| `NVINGEST_BROKER_PORT` | `7671` | NV-Ingest broker |
| `INGESTOR_PORT` | `8082` | Ingestor Server |
| `RAG_SERVER_PORT` | `8081` | RAG Server |
| `FRONTEND_PORT` | `3000` | Web UI |
| `EMBEDDING_PORT` | `9080` | Embedding NIM |
| `RANKING_PORT` | `1976` | Ranking NIM |
| `LLM_PORT` | `8999` | LLM NIM |
| `VLM_PORT` | `1977` | VLM NIM |
| `PAGE_ELEMENTS_PORT` | `8000` | Page Elements NIM |
| `GRAPHIC_ELEMENTS_PORT` | `8003` | Graphic Elements NIM |
| `TABLE_STRUCTURE_PORT` | `8016` | Table Structure NIM |
| `PADDLE_OCR_PORT` | `8009` | PaddleOCR NIM |

**Note:** The Singularity defaults deliberately differ from the Docker Compose
port assignments for some services. For example, the Docker Compose deployment
maps `table-structure` to host port `8006`, while the Singularity default is
`8016` — chosen to avoid a known conflict on the target HPC cluster. These
divergences are intentional and will not be unified.

To check for conflicts on a specific port before starting.

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
