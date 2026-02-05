# Singularity Definition Files

This directory contains Singularity definition files (.def) for building custom container images optimized for the RAG Blueprint deployment.

## Why Custom Definitions?

The public Docker images (etcd, MinIO, Milvus) don't include Singularity `%startscript` sections, which are required for `singularity instance start` to work properly. These definition files:

1. Bootstrap from the official Docker images
2. Add appropriate `%startscript` sections for background service execution
3. Configure proper command-line argument handling
4. Maintain compatibility with the original Docker image behavior

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

Once built, these images work with `singularity instance start`:

```bash
# Start etcd instance
singularity instance start \
  --bind /data/etcd:/etcd-data \
  etcd.sif \
  etcd-instance \
  --data-dir=/etcd-data \
  --listen-client-urls=http://0.0.0.0:2379

# Start MinIO instance
singularity instance start \
  --env MINIO_ROOT_USER=minioadmin \
  --env MINIO_ROOT_PASSWORD=minioadmin \
  --bind /data/minio:/data \
  minio.sif \
  minio-instance \
  server /data --address :9000

# Start Milvus instance
singularity instance start \
  --env ETCD_ENDPOINTS=localhost:2379 \
  --env MINIO_ADDRESS=localhost:9000 \
  --bind /data/milvus:/var/lib/milvus \
  milvus.sif \
  milvus-instance \
  run standalone
```

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
