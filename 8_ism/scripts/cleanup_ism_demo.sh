#!/bin/bash
# Cleanup ISM demo resources

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword@123!}"
CURL_OPTS="-ks"

echo "=== ISM Demo Cleanup ==="
echo ""

# Remove policy from indexes first
echo "1. Removing policy from managed indexes..."
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X POST "$LUCENIA_URL/_plugins/_ism/remove/logs-*"
echo ""

# Delete indexes
echo "2. Deleting log indexes..."
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X DELETE "$LUCENIA_URL/logs-*"
echo ""

# Delete policies
echo "3. Deleting ISM policies..."
curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X DELETE "$LUCENIA_URL/_plugins/_ism/policies/log_retention_policy"
echo ""

curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X DELETE "$LUCENIA_URL/_plugins/_ism/policies/simple_delete_policy" 2>/dev/null
echo ""

curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" \
  -X DELETE "$LUCENIA_URL/_plugins/_ism/policies/force_merge_policy" 2>/dev/null
echo ""

echo "=== Cleanup Complete ==="
