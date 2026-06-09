<!--
  SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->
# Get Started With the NVIDIA RAG Blueprint on HPC (Singularity)

Use the following documentation to deploy the NVIDIA RAG Blueprint on HPC clusters
using [Singularity](https://sylabs.io/singularity/), with self-hosted on-premises models.
This deployment path is intended for environments where Docker is not available,
such as shared HPC clusters managed by a job scheduler (Slurm, PBS, LSF).

For the Docker Compose deployment path, refer to
[Get Started With Docker Compose](deploy-docker-self-hosted.md).

:::{tip}
Every code block is meant to be **copied and pasted as-is** into your terminal.
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

- **Per-user exec sessions.** Each run of the stack creates a timestamped session
  directory under `$RAG_BASE_DIR/sessions/$USER/` for logs and runtime state. In
  batch mode the directory is named `exec_YYYY_MM_DD_<JOBID>`; in interactive mode
  it uses a date-indexed counter (`exec_YYYY_MM_DD_N`). Persistent data (vector
  database, object storage, model weights) lives outside the session directory and
  survives across sessions.

- **`SINGULARITY_TMPDIR=/tmp`.** Singularity requires a local POSIX filesystem to
  stage GPU driver libraries and namespace structures. Using Lustre or NFS for this
  breaks GPU access (`--nv`). The scripts hardcode `/tmp`, which is always local.


## Prerequisites

1. **Get an NGC API Key.** A free NGC account (any email) works — no paid
   subscription required.

   1. From the top-right profile menu → **Account Settings → API Keys** (or go
      directly to [org.ngc.nvidia.com/setup/api-keys](https://org.ngc.nvidia.com/setup/api-keys)),
      then click **Generate Personal Key** (expiration *Never Expire*).
   2. In the **Services Included** checklist, tick **NGC Catalog** — that alone
      authorises the `nvcr.io` pulls. Copy the key (`nvapi-...`).

   Full procedure and key-expiration handling: [Get an API Key](api-key.md).

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


## How It Works

Two key concepts shape how this deployment is organised on a shared HPC cluster.

### Shared data, per-user sessions

The base directory contains both shared and per-user data. Shared data is
downloaded once and read by every user and every job. Only the session directory
(logs, PIDs, runtime files) is per-user.

```
$RAG_BASE_DIR/
├── containers/{images,cache}/   ← shared (.sif files, ~60 GB)
├── db/                          ← shared (Milvus, MinIO, etcd state)
├── models/                      ← shared (NIM model weights, ~50 GB)
└── sessions/
    └── $USER/                   ← per-user (chmod 700)
        ├── rag-setup-<JOBID>.out
        └── exec_<DATE>_<JOBID>/
            ├── logs/
            ├── runtime/pids/
            └── tmp/
```

A new user submitting their first job inherits the existing shared data — no
60 GB re-download, no 50 GB re-cache. The `containers/` and `models/` trees are
effectively read-only at runtime and safe to share.

> **One instance per base directory.** The `db/` tree (etcd, MinIO, Milvus) is
> shared **and writable** and the service ports are fixed, so only **one** RAG
> instance can run against a given `RAG_BASE_DIR` at a time — a second would
> corrupt the shared database. A second submit is refused: `submit.sh` fails fast
> on the login node, and `deploy-on-node.sh` holds a lock
> (`$RAG_BASE_DIR/.rag-active.lock`), exiting with *"já existe uma instância do
> RAG em execução"* — released on `scancel`/shutdown and reclaimed if a crashed
> job left it stale. Running multiple **concurrent** instances
> (per-instance `db/` isolation) is future work — not supported yet.

### Cluster auto-detect

Site-specific values (`RAG_BASE_DIR`, Slurm partition, account, GPUs per node,
walltime) live in plain files under `deploy/singularity/run/clusters/`:

```
clusters/
├── gaia.conf      # Petrobras Gaia — A100, llm-tic account
└── lncc.conf      # LNCC Santos Dumont — H100, lm_manutencao account
```

The wrapper (`submit.sh`) reads `hostname -f` and sources the matching conf.
No `#SBATCH` directive is hard-coded inside the deployment scripts — every
site-specific flag comes from data, so the same scripts run unchanged on any
cluster once you add a conf file for it.


## Set Up the Working Directory (One-Time)

Export the NGC API Key.

```bash
export NGC_API_KEY="nvapi-..."
```

For the **batch** (recommended) flow, that is the only variable you need to set.
`RAG_BASE_DIR` and all Slurm-specific values are sourced from your cluster's
conf file in the next section.

For the **interactive** flow (alternative, see later in this guide), you must
also export `RAG_BASE_DIR` manually:

```bash
export RAG_BASE_DIR="/path/to/rag-workdir"
```

`RAG_BASE_DIR` is **required** in interactive mode — there is no default. The
scripts exit immediately with an error if it is unset, so you cannot
accidentally write ~100 GB of containers and model weights to a slow `$HOME`
NFS mount.

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


## Configure Your Cluster (One-Time)

The repository ships with two cluster confs (`gaia`, `lncc`). If your cluster
is one of them, skip to the next section. Otherwise, add a conf for your site.

### Check whether your cluster is recognised

From the login node:

```bash
hostname -f
```

Open `deploy/singularity/run/cluster-config.sh` and look for a regex that
matches your hostname. Two cases are pre-registered:

```bash
case "$host" in
    *gaia*.petrobras.com.br|gaiasc*|gaiab*)
        echo "gaia" ;;
    *lncc*|*sdumont*|*petrobr*)
        echo "lncc" ;;
esac
```

If no pattern matches, the wrapper prints an error listing the available
clusters and exits — `./submit.sh` will not run until you add a conf.

### Add a conf for a new cluster

1. Copy an existing conf and edit the values:

   ```bash
   cd deploy/singularity/run/clusters
   cp gaia.conf my-cluster.conf
   ```

2. Edit `my-cluster.conf` to match your site:

   ```bash
   RAG_BASE_DIR="${RAG_BASE_DIR:-/scratch/your-project/rag-workdir}"
   SLURM_PARTITION="your-gpu-partition"
   SLURM_ACCOUNT="your-account"
   SLURM_GPUS_PER_NODE=4
   SLURM_TIME=""               # empty = use partition default (effectively no limit)
   CLUSTER_GPU="A100"          # or H100, B200, etc.
   ```

   Discovery commands you can run on the login node:

   ```bash
   sinfo -o "%P %D %G"                   # list partitions and GPU configs
   sacctmgr show user $USER --json       # list Slurm accounts you can submit to
   nvidia-smi --query-gpu=name --format=csv,noheader  # GPU model
   ```

3. Add a hostname pattern in `cluster-config.sh`:

   ```bash
   case "$host" in
       *gaia*.petrobras.com.br|gaiasc*|gaiab*)
           echo "gaia" ;;
       *lncc*|*sdumont*|*petrobr*)
           echo "lncc" ;;
       *my-cluster*|*frontend*.my-cluster.edu)
           echo "my-cluster" ;;          # ← add this
   esac
   ```

4. Test that auto-detect works:

   ```bash
   source deploy/singularity/run/cluster-config.sh
   # → Cluster: my-cluster (A100) — /scratch/...
   ```

You can also bypass auto-detect with the `CLUSTER_NAME` environment variable:

```bash
CLUSTER_NAME=lncc ./submit.sh
```


## Pull Images (One-Time Setup)

Pull all required Singularity images from their registries. This step is
**login-node only** — it needs outbound internet access to `nvcr.io` and to
the public registries. It takes 30–60 minutes on first run and only needs to
be repeated when upgrading image versions. Images that already exist on disk
are skipped automatically.

```bash
cd deploy/singularity
./build-images.sh
```

If `RAG_BASE_DIR` is not yet set in the shell (you have not done the
interactive setup), the script will fail with a clear error. In that case,
either export it manually for the build, or source your cluster conf:

```bash
source run/cluster-config.sh
./build-images.sh
```

You should see output similar to the following.

```output
=== NVIDIA RAG Blueprint — Image Setup ===

RAG_BASE_DIR:      /gaia/finetune-llm/rag/runtime
Output directory:  /gaia/finetune-llm/rag/runtime/containers/images
Singularity cache: /gaia/finetune-llm/rag/runtime/containers/cache

✅ NGC auth configured for nvcr.io

[rag-server.sif] RAG Server v2.3.0
    Pulling from nvcr.io/nvidia/blueprint/rag-server:2.3.0...
    ✅ Pulled successfully
       Size: 8.2G
...
=== Summary ===
✅ Success: 16
❌ Failed:  0
```

Once complete, navigate to the run scripts directory.

```bash
cd run/
```


## Deploy via Slurm Batch (`./submit.sh`)

The recommended way to launch the RAG Blueprint is through the wrapper
`submit.sh`. It runs on the **login node**, auto-detects your cluster,
submits a Slurm batch job, prints a banner with the exact monitoring commands
ready to copy, and returns control to your shell in under a second.

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

The job runs on a compute node later, when Slurm allocates resources.

### Watching progress

`sbatch` is **asynchronous** — nothing prints to your terminal after the banner.
To watch the job, copy the `Follow` command:

```bash
tail -F /gaia/finetune-llm/rag/runtime/sessions/$USER/rag-setup-<JOBID>.out
```

The file appears once Slurm allocates a node. You first see the job's early
banner (`Job ID`, `Node`, `GPUs`, monitoring commands); after 15–20 minutes,
when all 9 startup steps finish, a `RAG Blueprint READY` banner prints the
frontend and API URLs.

:::{tip}
Pressing **Ctrl-C** on `tail` does **not** stop the job. It only stops following
the log. The job continues running on the compute node.
:::

### Walltime is unlimited by default

The cluster confs ship with `SLURM_TIME=""`. The wrapper omits the `--time`
flag entirely when this is empty, so the partition's default/max walltime
applies — effectively as long as the site policy allows. This matches the
expected use of the deployment as a long-lived service (multi-day inference
work), not a short batch job.

For short experiments where you want the job to clear the queue faster,
override on the CLI:

```bash
./submit.sh --time=04:00:00
```

Any extra arguments to `./submit.sh` are forwarded to `sbatch`.

### Safe to walk away

The wrapper is fire-and-forget. The job's compute-side script installs a
`SIGTERM`/`SIGINT` trap **before** running any startup step, so a `scancel`
at any point — even mid-infrastructure-startup — runs `99-stop-all.sh` and
shuts down every backgrounded service gracefully before the Slurm cgroup is
torn down. You can close your laptop after submitting; the job survives.


## Validate the Deployment

Once the `RAG Blueprint READY` banner appears in the log, all services are
expected to be healthy. The job script already runs `09-validate-all-services.sh`
as the last step of startup, so the log contains the full validation output.

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

To re-run validation manually from within the job's shell (or after `ssh`-ing
to the compute node), source the job's environment and run:

```bash
source $RAG_BASE_DIR/sessions/$USER/exec_*_<JOBID>/runtime/job.env  # optional, sets URLs
$(dirname $RAG_SLURM_OUT)/../../../deploy/singularity/run/09-validate-all-services.sh
```


## Use the Frontend

The compute node where your job runs is typically not directly reachable from
your laptop. Open an SSH tunnel through the login node.

```bash
ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    LOGIN_NODE ssh -L 8081:localhost:8081 -L 8082:localhost:8082 -L 3000:localhost:3000 \
    COMPUTE_NODE
```

Replace `LOGIN_NODE` with your cluster login hostname, and `COMPUTE_NODE` with
the node Slurm allocated for your job — find it with `squeue -j <JOBID> -o %N`.

After the tunnel is established, access services from your laptop:

| Service | URL on your laptop |
|---------|--------------------|
| Web UI | `http://localhost:3000` |
| RAG Server API docs | `http://localhost:8081/docs` |
| Ingestor API docs | `http://localhost:8082/docs` |

For details on the web UI, see [User Interface for NVIDIA RAG Blueprint](user-interface.md).


## Ingest Documents

Use the collection importer in `deploy/singularity/scripts/` to bulk-import
documents. Each first-level subdirectory of the root directory becomes a
separate collection on the server.

Install the required Python packages on the host where you will run the
importer (login node typically — the importer talks to the Ingestor Server
over HTTP through the SSH tunnel, or directly on the compute node):

```bash
pip install -r deploy/singularity/scripts/requirements.txt
```

If `pip install` fails on a network-restricted cluster, the importer can run
inside any singularity image that ships `requests` and `rich` — see the
[Collection Importer documentation](../deploy/singularity/scripts/README.md)
for the singularity-exec fallback.

Run a dry run first to validate file readability before uploading.

```bash
python3 deploy/singularity/scripts/ingest_collections.py \
  --root-dir /gaia/b04s/CONSORCIOS \
  --dry-run
```

Then run the full import.

```bash
python3 deploy/singularity/scripts/ingest_collections.py \
  --root-dir /gaia/b04s/CONSORCIOS
```

For the full list of options (parallel workers, batch size, dedup, specific
collections), refer to the
[Collection Importer documentation](../deploy/singularity/scripts/README.md).


## Stop the Job

To stop the batch deployment cleanly:

```bash
scancel <JOBID>
```

The job's `SIGTERM` trap runs `99-stop-all.sh` automatically, which stops
every backgrounded service (15+ processes including Ray actors, NIMs, Milvus,
etc.) before the Slurm cgroup is torn down. No orphans.

Everything stored under `RAG_BASE_DIR` is preserved across shutdowns:

| Path | Contents |
|------|----------|
| `$RAG_BASE_DIR/db/` | Milvus vector database, MinIO objects, etcd state |
| `$RAG_BASE_DIR/models/` | NIM model weights (no re-download on next start) |
| `$RAG_BASE_DIR/containers/images/` | `.sif` images (no re-pull on next start) |
| `$RAG_BASE_DIR/containers/cache/` | Singularity image cache |
| `$RAG_BASE_DIR/sessions/$USER/exec_*/logs/` | Per-job logs (kept for inspection) |


## Common Errors and Troubleshooting

### `ERROR: NGC_API_KEY is not set` (on `./submit.sh`)

The wrapper validates `NGC_API_KEY` on the login node before consuming any
queue time. Export it and retry:

```bash
export NGC_API_KEY="nvapi-..."
./submit.sh
```

### `ERROR: Cannot detect cluster from hostname '...'`

The hostname did not match any regex in `cluster-config.sh`. Either add a
pattern (see [Configure Your Cluster](#configure-your-cluster-one-time)) or
force a specific cluster:

```bash
CLUSTER_NAME=lncc ./submit.sh
```

### `ERROR: <FIELD> is empty after sourcing <conf>`

A required field is missing from the cluster conf. The error names which one
(`RAG_BASE_DIR`, `SLURM_PARTITION`, `SLURM_ACCOUNT`, `SLURM_GPUS_PER_NODE`, or
`CLUSTER_GPU`). Open the named conf and add the assignment.

### Slurm output file does not appear after submit

The Slurm output is created when Slurm allocates a node and the job actually
starts. While the job is still in the queue (`squeue -j <JOBID>` shows state
`PD`), no log file exists yet. Once the state becomes `R`, the file appears
within seconds. Use `tail -F` (capital F) so it follows the file once it
shows up — `-F` retries on `ENOENT`.

### `tail -F` shows nothing but the early banner; no further progress

Common causes:

1. The job is waiting on the Slurm scheduler — check `squeue -j <JOBID>`.
2. NIM model weights are being downloaded on first run — first-load can take
   30–60 minutes for the 49B LLM. Watch `$RAG_BASE_DIR/sessions/$USER/exec_*/logs/nim-llm.log`.
3. A NIM crashed silently — inspect the corresponding `*.log` in the same
   `logs/` dir.

### `scancel` did not free GPU memory

The `SIGTERM` trap normally runs `99-stop-all.sh` and waits for graceful
shutdown. If Slurm sent `SIGKILL` immediately (some sites do this), no trap
runs. On the compute node, run `99-stop-all.sh` manually as the same user, or
ask the site admin to give the job grace time on cancel.


## Alternative: Interactive Mode (01–09 step by step)

The interactive path runs the same 9 startup scripts that `deploy-on-node.sh`
chains together, but one at a time from your shell. Use it for:

- Learning what each step does
- Debugging a specific service that fails to start (re-run only that step)
- Restarting just the application layer (06–08) without touching the NIMs

Re-export `NGC_API_KEY` and `RAG_BASE_DIR` if you are starting a new shell session.

```bash
export NGC_API_KEY="nvapi-..."
export RAG_BASE_DIR="/path/to/rag-workdir"
cd deploy/singularity/run
```


### 1. Start infrastructure services

Start etcd, MinIO, and Milvus. This also stops any services left over from a previous
session and creates a fresh timestamped session directory under
`$RAG_BASE_DIR/sessions/$USER/`.

```bash
./01-start-infrastructure.sh
```

```output
=== Cleaning up previous session ===
   No previous session found
   ✅ Cleanup done

=== New session: exec_2026_05_28_1 (user: jpnavarro) ===

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


### 4. Wait for NIMs to be ready

Wait for all NIMs to pass their health checks. **On first run**, NIMs download and
cache their model weights — this can take 5–30 minutes depending on model size and
available bandwidth. Subsequent starts take 2–5 minutes.

```bash
./04-wait-nim-models.sh
```

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
   Table Structure      8016    ✅ ready (1m24s)
   PaddleOCR            8009    ✅ ready (1m19s)

=== All 8 NIMs ready ===
```


### 5. Start NV-Ingest

Start the NV-Ingest document processing microservice. This script **blocks** until
the internal Ray pipeline is fully initialised (2–5 minutes cold start).

```bash
./05-start-nv-ingest-ms.sh
```


### 6. Start the Ingestor Server

Start the document ingestion API.

```bash
./06-start-ingest-server.sh
```

Verify the ingestor server is ready:

```bash
curl -s http://localhost:8082/health
```


### 7. Start the RAG Server

Start the RAG query orchestrator.

```bash
./07-start-rag-server.sh
```

Verify the RAG server is ready:

```bash
curl -s http://localhost:8081/health
```


### 8. Start the Frontend (optional)

Start the web UI.

```bash
./08-start-frontend.sh
```


### 9. Validate

Run the full health check.

```bash
./09-validate-all-services.sh
```


### Stopping the interactive deployment

```bash
./99-stop-all.sh
```


## Alternative: Direct sbatch (without the wrapper)

You can call `deploy-on-node.sh` directly via `sbatch`, but you must supply
the cluster-specific flags yourself — the script intentionally has no
`#SBATCH --account`, `--partition`, `--gres`, `--time`, or `--output`:

```bash
sbatch --account=ACCOUNT --partition=PART --gres=gpu:4 \
       --output=$RAG_BASE_DIR/sessions/$USER/rag-setup-%j.out \
       --export=ALL deploy-on-node.sh
```

The wrapper is the recommended path because it handles all of this
automatically from the cluster conf, validates env vars on the login node,
and writes its output to the per-user sessions dir.


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

The Slurm output file itself is also symlinked into the per-exec logs dir for
one-stop debugging:

```bash
tail -f $RAG_BASE_DIR/sessions/$USER/exec_*_<JOBID>/logs/slurm.out
```

### GPU allocation

The default layout assumes 4 GPUs (A100 80 GB or H100 80 GB). The 49B LLM
requires 2× 80 GB in tensor-parallel mode. To change GPU assignments, edit
the relevant `run/nim/nim-*.sh` script and update the `CUDA_VISIBLE_DEVICES`
variable before running `03-start-nim-models.sh` (interactive mode), or
adapt the layout before submitting a batch job.

### Re-running without restarting NIMs

NIMs take the longest to start. If you only need to restart the application
layer (ingestor server, RAG server, frontend), `ssh` into the compute node
(or use interactive mode) and run scripts 06–08 individually without re-running
scripts 03–05.

### Port conflicts

HPC clusters often have ports already occupied by other services — MPI daemons,
scheduler agents, monitoring exporters, or other users' workloads. Because
Singularity runs on the **shared host network**, every port used by the blueprint
must be free on the compute node.

Every service port has a configurable default. To override a port, export the
corresponding variable **before** launching the deployment.

```bash
export TABLE_STRUCTURE_PORT=8026   # change only what conflicts
./submit.sh
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

To check for conflicts on a specific port before starting:

```bash
lsof -i :8081
lsof -i :8082
lsof -i :3000
```

### Optional feature flags

Feature flags that are purely env-var controlled — such as `ENABLE_QUERYREWRITER`,
`ENABLE_REFLECTION`, `ENABLE_QUERY_DECOMPOSITION`, `ENABLE_FILTER_GENERATOR`, and
`ENABLE_VLM_INFERENCE` — are supported. Export them before launching:

```bash
export ENABLE_QUERYREWRITER=True
export ENABLE_REFLECTION=true
./submit.sh
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


## Related Topics

- [NVIDIA RAG Blueprint Documentation](readme.md)
- [Get Started With Docker Compose](deploy-docker-self-hosted.md)
- [Collection Importer](../deploy/singularity/scripts/README.md)
- [Best Practices for Common Settings](accuracy_perf.md)
- [Troubleshoot](troubleshooting.md)
