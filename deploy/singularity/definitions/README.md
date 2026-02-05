# Singularity Definition Files

This directory contains Singularity definition files (.def) for building custom container images optimized for the RAG Blueprint deployment.

## Why Custom Definitions?

The public Docker images (etcd, MinIO, Milvus) are built from definition files to:

1. Bootstrap from the official Docker images
2. Add proper `%startscript` sections (for future compatibility)
3. Ensure the correct binary paths are used
4. Maintain compatibility with the original Docker image behavior

**Note:** Due to limitations in Apptainer 1.4.5 with `singularity instance start` and startscripts from Docker-based images, the deployment uses `singularity exec` in background mode instead. The startscripts are included for future compatibility when this limitation is resolved.

## Available Definitions

| File | Base Image | Purpose |
|------|------------|---------|
| `etcd.def` | quay.io/coreos/etcd:v3.6.5 | etcd key-value store for Milvus |
| `minio.def` | minio/minio:RELEASE.2023-03-20T20-16-18Z | MinIO object storage |
| `milvus.def` | milvusdb/milvus:v2.4.17 | Milvus vector database |

## Building Images

### Build All Images

```bash
cd deploy/singularity/scripts
./build-custom-images.sh
```

### Build Individual Image

```bash
cd deploy/singularity/definitions

# Build etcd
singularity build etcd.sif etcd.def

# Build MinIO
singularity build minio.sif minio.def

# Build Milvus
singularity build milvus.sif milvus.def
```

### Build with Custom Output Directory

```bash
export RAG_IMAGES_DIR=/path/to/images
singularity build $RAG_IMAGES_DIR/etcd.sif etcd.def
```

## Using Built Images

Once built, these images are used with `singularity exec` in background mode:

```bash
# Start etcd
singularity exec \
  --bind /data/etcd:/etcd-data \
  etcd.sif \
  /usr/local/bin/etcd \
    --data-dir=/etcd-data \
    --listen-client-urls=http://0.0.0.0:2379 \
  > etcd.log 2>&1 &

# Start MinIO
singularity exec \
  --env MINIO_ROOT_USER=minioadmin \
  --env MINIO_ROOT_PASSWORD=minioadmin \
  --bind /data/minio:/data \
  minio.sif \
  /usr/bin/minio server /data --address :9000 \
  > minio.log 2>&1 &

# Start Milvus
singularity exec \
  --env ETCD_ENDPOINTS=localhost:2379 \
  --env MINIO_ADDRESS=localhost:9000 \
  --bind /data/milvus:/var/lib/milvus \
  milvus.sif \
  /usr/bin/milvus run standalone \
  > milvus.log 2>&1 &
```

See `deploy/singularity/test/` for complete orchestration examples.

## Notes

- **NGC Authentication**: Not required for these public images
- **Build Time**: Each image takes 2-5 minutes to build
- **Disk Space**: Plan for ~500MB per image
- **Permissions**: Building requires write access to the output directory
- **Compatibility**: Built images are compatible with Apptainer/Singularity 1.0+

## Updating Versions

To update to newer versions, edit the `From:` line in the respective .def file:

```bash
Bootstrap: docker
From: milvusdb/milvus:v2.5.0  # Change version here
```

Then rebuild the image.
