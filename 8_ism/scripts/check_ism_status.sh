#!/bin/bash
# Check ISM status for all managed indexes

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword@123!}"
CURL_OPTS="-ks"

echo "=== ISM Status Check ==="
echo ""

# List all policies
echo "--- All ISM Policies ---"
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X GET "$LUCENIA_URL/_plugins/_ism/policies?pretty"
echo ""

# Check status of logs indexes
echo "--- Managed Index Status (logs-*) ---"
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X GET "$LUCENIA_URL/_plugins/_ism/explain/logs-*?pretty"
echo ""

# Show index info
echo "--- Index Information ---"
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X GET "$LUCENIA_URL/_cat/indices/logs-*?v"
echo ""
