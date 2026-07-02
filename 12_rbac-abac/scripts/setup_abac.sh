#!/bin/bash
# RBAC/ABAC Demo - Attribute-Based Access Control (ABAC) Setup
#
# ABAC = a user's ATTRIBUTES determine what they can access. Instead of writing
# one role per department, we write ONE reusable role whose document-level
# security query is parameterized by each user's `permissions` attribute.
#
# The DLS query uses a `terms_set` query:
#   - A document's `security_attributes` are matched against the terms injected
#     from the user's attribute:  ${attr.internal.permissions}
#   - minimum_should_match_script = doc['security_attributes'].length means a
#     document is visible ONLY IF the user holds EVERY attribute the document
#     requires. Add attributes to a user and they see more documents - no role
#     changes required.

set -e

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== ABAC Setup ==="
echo ""

echo "1. Creating single reusable role 'abac_reader' (DLS driven by user attributes)..."
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/roles/abac_reader" \
  -H 'Content-Type: application/json' \
  -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["documents"],
    "dls": "{\"terms_set\": {\"security_attributes\": {\"terms\": [${attr.internal.permissions}], \"minimum_should_match_script\": {\"source\": \"doc['\''security_attributes'\''].length\"}}}}",
    "allowed_actions": ["read"]
  }]
}'
echo ""

echo "2. Creating users with different permission ATTRIBUTES (same role)..."
# carol works in engineering at the internal level.
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/internalusers/carol" \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "EngReader123!",
  "opendistro_security_roles": ["abac_reader"],
  "attributes": {
    "permissions": "\"dept_eng\", \"level_internal\""
  }
}'
echo ""

# dave works in sales and can see both public and internal sales material.
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/internalusers/dave" \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "SalesReader123!",
  "opendistro_security_roles": ["abac_reader"],
  "attributes": {
    "permissions": "\"dept_sales\", \"level_public\", \"level_internal\""
  }
}'
echo ""

echo "=== ABAC setup complete ==="
echo "Users created (all share the SAME role 'abac_reader'):"
echo "  carol / EngReader123! -> permissions: dept_eng, level_internal"
echo "  dave  / SalesReader123!  -> permissions: dept_sales, level_public, level_internal"
echo ""
echo "carol will see only docs whose security_attributes are a subset of hers"
echo "(the Engineering Roadmap: [dept_eng, level_internal])."
echo ""
echo "Next: run ./scripts/test_access.sh to see ABAC in action."
