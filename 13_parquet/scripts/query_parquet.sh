#!/bin/bash
# Parquet Index-Free Search Demo - Query a mounted Parquet index
#
# A mounted index answers _search, _count, and GET. The supported query surface
# is deliberately narrow (it runs directly against the Parquet file):
#   WORKS:      numeric range/term queries, numeric aggregations,
#               keyword term/match queries, exists, GET by _id
#   DOES NOT:   keyword aggregations, sorting, boolean-column queries, and any
#               write (index/update/delete/_bulk is rejected 400 read-only)
# The "does not work" cases become available after promotion (see
# ./scripts/promote_reindex.sh).

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

# _search returning hits
search() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
      -X POST "$LUCENIA_URL/mtcars/_search?pretty" \
      -H 'Content-Type: application/json' -d "$1"
}
# _search returning only the aggregations block
agg() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
      -X POST "$LUCENIA_URL/mtcars/_search?filter_path=aggregations&pretty" \
      -H 'Content-Type: application/json' -d "$1"
}
# _count returning just a document count
count() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
      -X POST "$LUCENIA_URL/mtcars/_count?pretty" \
      -H 'Content-Type: application/json' -d "$1"
}

hr() { echo "=================================================="; }

hr; echo " 1. Numeric RANGE query - cars with 31.0 <= mpg <= 35.0"; hr
search '{ "size": 20, "_source": ["model","mpg"], "query": { "range": { "mpg": { "gte": 31.0, "lte": 35.0 } } } }' \
  | grep -E '"model"|"mpg"'
echo ""

hr; echo " 2. Keyword TERM query - the car named 'Valiant'"; hr
search '{ "_source": ["model","hp","cyl"], "query": { "term": { "model": "Valiant" } } }' \
  | grep -E '"model"|"hp"|"cyl"'
echo ""

hr; echo " 3. Numeric AGGREGATION - average mpg and max hp (works)"; hr
agg '{ "size": 0, "aggs": { "avg_mpg": { "avg": { "field": "mpg" } }, "max_hp": { "max": { "field": "hp" } } } }' \
  | grep -E '"avg_mpg"|"max_hp"|"value"'
echo ""

hr; echo " 4. TIMESTAMP is a long - query last_serviced as epoch millis"; hr
echo "    (dates map to long epoch-millis; use a numeric range, not a date range)"
# 2026-10-01T00:00:00Z = 1790812800000
search '{ "size": 5, "_source": ["model","last_serviced"], "query": { "range": { "last_serviced": { "gte": 1790812800000 } } } }' \
  | grep -E '"model"|"last_serviced"'
echo ""

hr; echo " 5. EXISTS query - how many rows have an hp value"; hr
count '{ "query": { "exists": { "field": "hp" } } }' | grep -E '"count"'
echo ""

hr; echo " 6. GET a single document by its _id (the 'model' column value)"; hr
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X GET "$LUCENIA_URL/mtcars/_doc/Camaro%20Z28?pretty" \
  | grep -E '"_id"|"mpg"|"hp"|"am"'
echo ""

hr; echo " LIMITATIONS (these are expected to fail on a mounted index)"; hr

echo ">> 7a. Keyword AGGREGATION on 'model' - unsupported on a mount"
search '{ "size": 0, "aggs": { "by_model": { "terms": { "field": "model" } } } }' \
  | grep -E '"reason"|"status"' | head -2
echo ""

echo ">> 7b. SORT on a keyword field - unsupported on a mount"
search '{ "size": 3, "sort": [ { "model": "asc" } ], "query": { "match_all": {} } }' \
  | grep -E '"reason"|"status"' | head -2
echo ""

echo ">> 7c. BOOLEAN column query on 'am' - not directly queryable on a mount"
echo "    (the value is still present in _source; it becomes queryable after reindex)"
search '{ "size": 20, "_source": ["model","am"], "query": { "term": { "am": true } } }' \
  | grep -E '"reason"|"status"' | head -2
echo ""

echo ">> 7d. WRITE attempt - a mounted index is read-only"
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X POST "$LUCENIA_URL/mtcars/_doc?pretty" \
  -H 'Content-Type: application/json' \
  -d '{ "model": "DeLorean" }' \
  | grep -E '"reason"|"status"' | head -2
echo ""

echo "Done. To unlock keyword aggregations, sorting, and boolean queries,"
echo "promote the mount to a regular index: ./scripts/promote_reindex.sh"
