#!/bin/bash
# Parquet Index-Free Search Demo - Sample Data Generator
#
# Writes the sample Parquet file to node/config/data/cars.parquet, which the
# docker-compose file mounts into the node's config directory. If a local
# python3 + pyarrow is available it is used directly; otherwise the file is
# generated inside a throwaway python:3.12-slim container, so Docker alone is
# sufficient (no local Python or pyarrow required).

set -e

# Resolve paths relative to this script so it works from any directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"

OUT_DIR="$TUTORIAL_DIR/node/config/data"
OUT_FILE="$OUT_DIR/cars.parquet"

echo "=== Parquet Demo - Generate sample data ==="
echo ""

mkdir -p "$OUT_DIR"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import pyarrow' >/dev/null 2>&1; then
    echo "Using local python3 + pyarrow..."
    python3 "$TUTORIAL_DIR/generate_cars_parquet.py" "$OUT_FILE"
else
    echo "Local pyarrow not found - generating inside a python:3.12-slim container..."
    # Run as the host user (and give pip a writable HOME) so the generated file
    # is owned by you, not root, on Linux hosts.
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$TUTORIAL_DIR":/work \
        -w /work \
        python:3.12-slim \
        bash -c "pip install --quiet --user pyarrow && python generate_cars_parquet.py node/config/data/cars.parquet"
fi

echo ""
echo "=== Sample data ready ==="
echo "Wrote: $OUT_FILE"
echo "Inside the container this is visible as the relative path: data/cars.parquet"
echo "Next: docker compose up -d, then ./scripts/mount_parquet.sh"
