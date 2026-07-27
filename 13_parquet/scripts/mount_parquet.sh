#!/bin/bash
# Parquet Index-Free Search Demo - Mount a Parquet file as a read-only index
#
# Mounts node/config/data/cars.parquet (visible inside the container as the
# relative path "data/cars.parquet") as a read-only index called `mtcars`.
# Lucenia validates the file, infers field mappings from the Parquet footer,
# and serves queries by reading data pages directly from the file - no data is
# copied or ingested.

set -e

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== Parquet Demo - Mount ==="
echo ""

echo "0. Confirm the node is reachable and the parquet module is loaded..."
if ! lucenia_curl -o /dev/null -w '%{http_code}' -X GET "$LUCENIA_URL/_cluster/health" | grep -q '^200$'; then
    echo "Cannot reach a healthy node at $LUCENIA_URL - is the cluster up (docker compose up -d) and the port correct?"
    exit 1
fi
# On 0.12.0 the module is listed as "parquet [module]" (not "ParquetCodecPlugin").
lucenia_curl -X GET "$LUCENIA_URL/_cat/plugins?v" | grep -i parquet \
    || echo "(parquet module not listed - is this Lucenia 0.12.0+?)"
echo ""

# Relative paths resolve against the node config directory and are always
# allowed - no parquet.allowed_paths entry is required.
if lucenia_curl -o /dev/null -w '%{http_code}' -X GET "$LUCENIA_URL/mtcars" | grep -q '^200$'; then
    echo "1. Index 'mtcars' is already mounted - skipping the mount."
    echo "   Run ./scripts/cleanup.sh first if you want to re-mount."
else
    echo "1. Mounting data/cars.parquet as index 'mtcars' (id_column = model)..."
    lucenia_curl -X PUT "$LUCENIA_URL/_plugins/parquet/mtcars?pretty" \
      -H 'Content-Type: application/json' \
      -d '{
      "path": "data/cars.parquet",
      "id_column": "model"
    }'
fi
echo ""

echo "2. Inspecting the inferred mapping..."
lucenia_curl -X GET "$LUCENIA_URL/mtcars/_mapping?pretty"
echo ""

echo "=== Mount complete ==="
echo "The 'mtcars' index is now a read-only view over cars.parquet."
echo "Notice in the mount response:"
echo "  - model  -> keyword   mpg/wt -> double   cyl/hp/gear -> integer"
echo "  - am     -> boolean   (preserved in _source, not queryable until reindex)"
echo "  - last_serviced -> long (epoch milliseconds, NOT a date type)"
echo "  - raw_signature is listed under skipped_columns (non-string binary)"
echo ""
echo "Next: ./scripts/query_parquet.sh"
