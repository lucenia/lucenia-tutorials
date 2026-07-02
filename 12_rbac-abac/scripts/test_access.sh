#!/bin/bash
# RBAC/ABAC Demo - Verify Access Control
#
# Runs the same search (match_all) as each user and prints which document
# titles come back. Because DLS/FLS are applied transparently, each user gets a
# filtered view of the exact same index.

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
CURL_OPTS="-ks"

# Run a match_all search as a given user and list the titles they can see.
search_as() {
    local user="$1"
    local pass="$2"
    echo "--- Results visible to '$user' ---"
    curl $CURL_OPTS -u "$user:$pass" \
      -X GET "$LUCENIA_URL/documents/_search?pretty" \
      -H 'Content-Type: application/json' \
      -d '{ "size": 20, "query": { "match_all": {} } }' \
      | grep -E '"title"|"salary_info"|"security_exception"|"status"' \
      || echo "(no output)"
    echo ""
}

echo "=================================================="
echo " ADMIN (superuser) - sees everything"
echo "=================================================="
search_as "admin" "${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"

echo "=================================================="
echo " RBAC"
echo "=================================================="
echo ">> bob (role hr_reader) should see ONLY HR documents"
search_as "bob" "HrReaderPass123!"

echo ">> alice (role public_reader) should see ONLY public docs, salary_info hidden"
search_as "alice" "PublicReaderPass123!"

echo "=================================================="
echo " ABAC (both users share the role 'abac_reader')"
echo "=================================================="
echo ">> carol (permissions: dept_eng, level_internal)"
echo "   should see ONLY the Engineering Roadmap"
search_as "carol" "EngReader123!"

echo ">> dave (permissions: dept_sales, level_public, level_internal)"
echo "   should see the sales public + internal docs"
search_as "dave" "SalesReader123!"

echo "=================================================="
echo " Negative test: bob tries to WRITE (should be forbidden)"
echo "=================================================="
curl $CURL_OPTS -u "bob:HrReaderPass123!" \
  -X POST "$LUCENIA_URL/documents/_doc" \
  -H 'Content-Type: application/json' \
  -d '{ "title": "bob was here" }' \
  | grep -E '"type"|"status"|"reason"' || echo "(request completed)"
echo ""
