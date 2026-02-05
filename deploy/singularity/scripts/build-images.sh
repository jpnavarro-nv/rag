#!/bin/bash
# Build custom Singularity images with startscript support
# These images enable 'singularity instance start' for background services

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEF_DIR="$SCRIPT_DIR/../definitions"
OUTPUT_DIR="${RAG_IMAGES_DIR:-$SCRIPT_DIR/../../../containers/images}"

echo "=== Building Custom Singularity Images ==="
echo ""
echo "Definition files: $DEF_DIR"
echo "Output directory: $OUTPUT_DIR"
echo ""

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Function to build an image
build_image() {
    local def_file=$1
    local sif_name=$2
    local description=$3

    echo "[$sif_name] $description"

    if [ -f "$OUTPUT_DIR/$sif_name" ]; then
        echo "    ⚠️  $sif_name already exists"
        read -p "    Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "    ⊘  Skipped"
            return 0
        fi
        rm -f "$OUTPUT_DIR/$sif_name"
    fi

    echo "    Building from $def_file..."
    if singularity build "$OUTPUT_DIR/$sif_name" "$DEF_DIR/$def_file"; then
        echo "    ✅ Built successfully"
        ls -lh "$OUTPUT_DIR/$sif_name" | awk '{print "       Size:", $5}'
    else
        echo "    ❌ Build failed"
        return 1
    fi
    echo ""
}

# Track build results
SUCCESS=0
FAILED=0

# Build infrastructure images
echo "=== Infrastructure Images ==="
echo ""

build_image "etcd.def" "etcd.sif" "etcd v3.6.5 - Key-value store" && SUCCESS=$((SUCCESS + 1)) || FAILED=$((FAILED + 1))
build_image "minio.def" "minio.sif" "MinIO - Object storage" && SUCCESS=$((SUCCESS + 1)) || FAILED=$((FAILED + 1))
build_image "milvus.def" "milvus.sif" "Milvus v2.6.2-gpu - Vector database" && SUCCESS=$((SUCCESS + 1)) || FAILED=$((FAILED + 1))

# Summary
echo "=== Build Summary ==="
echo "✅ Success: $SUCCESS"
echo "❌ Failed:  $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "🎉 All images built successfully!"
    echo ""
    echo "Images location: $OUTPUT_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Test instance start: singularity instance start $OUTPUT_DIR/etcd.sif test-instance"
    echo "  2. Run test scripts: cd ../test && ./01-start-infrastructure.sh"
else
    echo "⚠️  Some builds failed. Check errors above."
    exit 1
fi
