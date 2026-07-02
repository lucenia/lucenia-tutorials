#!/bin/bash
# RBAC/ABAC Demo - Cleanup
# Removes the users, roles, and index created by this tutorial.

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== RBAC/ABAC Demo Cleanup ==="
echo ""

echo "1. Deleting internal users..."
for u in alice bob carol dave; do
    lucenia_curl -X DELETE "$LUCENIA_URL/_plugins/_security/api/internalusers/$u"
    echo ""
done

echo "2. Deleting roles..."
for r in hr_reader public_reader abac_reader; do
    lucenia_curl -X DELETE "$LUCENIA_URL/_plugins/_security/api/roles/$r"
    echo ""
done

echo "3. Deleting the 'documents' index..."
lucenia_curl -X DELETE "$LUCENIA_URL/documents"
echo ""

echo "=== Cleanup complete ==="
