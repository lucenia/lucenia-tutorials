#!/bin/bash
# Parquet Index-Free Search Demo - Cleanup
#
# Deletes the indices created by this tutorial. Deleting the mounted 'mtcars'
# index removes only the read-only view - the underlying cars.parquet file on
# disk is never touched.

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== Parquet Demo - Cleanup ==="
echo ""

echo "1. Deleting mounted index 'mtcars' (leaves cars.parquet untouched)..."
lucenia_curl -X DELETE "$LUCENIA_URL/mtcars?pretty" | grep -E '"acknowledged"|"status"|"type"' || true
echo ""

echo "2. Deleting regular index 'mtcars_ingested'..."
lucenia_curl -X DELETE "$LUCENIA_URL/mtcars_ingested?pretty" | grep -E '"acknowledged"|"status"|"type"' || true
echo ""

echo "=== Cleanup complete ==="
echo "The sample file node/config/data/cars.parquet is still on disk."
echo "To stop the node:            docker compose down"
echo "To also remove its volume:   docker compose down -v"
