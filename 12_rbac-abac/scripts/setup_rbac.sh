#!/bin/bash
# RBAC/ABAC Demo - Role-Based Access Control (RBAC) Setup
#
# RBAC = a user's ROLE determines what they can access. We create two roles
# with fixed, role-specific rules, map each to a user, and let the role decide
# which documents and fields are visible.
#
#   - hr_reader:     sees only HR documents (document-level security)
#   - public_reader: sees only PUBLIC documents, with salary_info hidden
#                    (document-level + field-level security)

set -e

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== RBAC Setup ==="
echo ""

echo "1. Creating role 'hr_reader' (document-level security: department = hr)..."
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/roles/hr_reader" \
  -H 'Content-Type: application/json' \
  -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["documents"],
    "dls": "{\"term\": {\"department\": \"hr\"}}",
    "allowed_actions": ["read"]
  }]
}'
echo ""

echo "2. Creating role 'public_reader' (DLS: classification = public, FLS: hide salary_info)..."
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/roles/public_reader" \
  -H 'Content-Type: application/json' \
  -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["documents"],
    "dls": "{\"term\": {\"classification\": \"public\"}}",
    "fls": ["~salary_info"],
    "allowed_actions": ["read"]
  }]
}'
echo ""

echo "3. Creating internal users..."
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/internalusers/bob" \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "HrReaderPass123!",
  "opendistro_security_roles": ["hr_reader"]
}'
echo ""

lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/internalusers/alice" \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "PublicReaderPass123!",
  "opendistro_security_roles": ["public_reader"]
}'
echo ""

echo "=== RBAC setup complete ==="
echo "Users created:"
echo "  bob   / HrReaderPass123!     -> role hr_reader     (only HR docs)"
echo "  alice / PublicReaderPass123! -> role public_reader (only public docs, no salary_info)"
echo ""
echo "Next: run ./scripts/test_access.sh to see RBAC in action."
