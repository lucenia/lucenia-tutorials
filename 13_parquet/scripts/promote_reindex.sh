#!/bin/bash
# Parquet Index-Free Search Demo - Promote a mount to a regular index
#
# A mounted Parquet index is read-only with a narrow query surface. The standard
# _reindex API copies its rows into a normal Lucenia index that has the full
# feature set: Lucene points, keyword field data, aggregations, and sorting.
# If the mount was created with an id_column, those _id values are carried over.

# NOTE: no `set -e` here - the grep filters below return non-zero when they find
# no match, which under `set -e` would abort the script mid-run.

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== Parquet Demo - Promote via _reindex ==="
echo ""

if ! lucenia_curl -o /dev/null -w '%{http_code}' -X GET "$LUCENIA_URL/mtcars" | grep -q '^200$'; then
    echo "Source index 'mtcars' not found - run ./scripts/mount_parquet.sh first."
    exit 1
fi

echo "1. Reindexing mounted 'mtcars' -> regular index 'mtcars_ingested'..."
lucenia_curl -X POST "$LUCENIA_URL/_reindex?refresh=true&pretty" \
  -H 'Content-Type: application/json' \
  -d '{
  "source": { "index": "mtcars" },
  "dest":   { "index": "mtcars_ingested" }
}' | grep -E '"took"|"created"|"total"|"failures"'
echo ""

echo "2. Keyword AGGREGATION now works (count cars by gear)..."
lucenia_curl -X POST "$LUCENIA_URL/mtcars_ingested/_search?filter_path=aggregations.by_gear.buckets&pretty" \
  -H 'Content-Type: application/json' \
  -d '{ "size": 0, "aggs": { "by_gear": { "terms": { "field": "gear" } } } }' \
  | grep -E '"key"|"doc_count"'
echo ""

echo "3. SORT now works (three lightest cars by weight)..."
lucenia_curl -X POST "$LUCENIA_URL/mtcars_ingested/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{ "size": 3, "_source": ["model","wt"], "sort": [ { "wt": "asc" } ] }' \
  | grep -E '"model"|"wt"'
echo ""

echo "4. BOOLEAN column 'am' is now queryable (count manual-transmission cars)..."
lucenia_curl -X POST "$LUCENIA_URL/mtcars_ingested/_count?pretty" \
  -H 'Content-Type: application/json' \
  -d '{ "query": { "term": { "am": true } } }' \
  | grep -E '"count"'
echo ""

echo "5. The _id values (car model names) were preserved by the reindex..."
lucenia_curl -X GET "$LUCENIA_URL/mtcars_ingested/_doc/Lotus%20Europa?pretty" \
  | grep -E '"_id"|"mpg"|"wt"'
echo ""

echo "=== Promotion complete ==="
echo "'mtcars_ingested' is a normal index with the full query surface."
echo "The mounted 'mtcars' index can now be safely deleted - doing so never"
echo "touches the underlying cars.parquet file. See ./scripts/cleanup.sh."
