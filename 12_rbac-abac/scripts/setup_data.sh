#!/bin/bash
# RBAC/ABAC Demo - Data Setup
# Creates the shared `documents` index and loads sample records that are
# tagged by department, classification, and security_attributes. These same
# documents are used to demonstrate both RBAC and ABAC access control.

set -e

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

# Always run requests as the admin superuser for setup.
lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

echo "=== RBAC/ABAC Demo - Data Setup ==="
echo ""

echo "1. Creating the 'documents' index with an explicit mapping..."
# security_attributes MUST be a keyword field for the ABAC terms_set query to work.
lucenia_curl -X PUT "$LUCENIA_URL/documents" \
  -H 'Content-Type: application/json' \
  -d '{
  "mappings": {
    "properties": {
      "title":               { "type": "text" },
      "department":          { "type": "keyword" },
      "classification":      { "type": "keyword" },
      "owner":               { "type": "keyword" },
      "salary_info":         { "type": "text" },
      "security_attributes": { "type": "keyword" }
    }
  }
}'
echo ""

echo "2. Bulk loading sample documents..."
lucenia_curl -X POST "$LUCENIA_URL/_bulk" \
  -H 'Content-Type: application/x-ndjson' \
  --data-binary '
{ "index": { "_index": "documents", "_id": "1" } }
{ "title": "Company Handbook", "department": "hr", "classification": "public", "owner": "hr-team", "salary_info": "N/A", "security_attributes": ["dept_hr", "level_public"] }
{ "index": { "_index": "documents", "_id": "2" } }
{ "title": "HR Salary Bands 2026", "department": "hr", "classification": "restricted", "owner": "hr-team", "salary_info": "Band A: 120k-160k", "security_attributes": ["dept_hr", "level_restricted"] }
{ "index": { "_index": "documents", "_id": "3" } }
{ "title": "Engineering Roadmap", "department": "engineering", "classification": "internal", "owner": "eng-team", "salary_info": "N/A", "security_attributes": ["dept_eng", "level_internal"] }
{ "index": { "_index": "documents", "_id": "4" } }
{ "title": "Production Secrets Rotation", "department": "engineering", "classification": "restricted", "owner": "eng-team", "salary_info": "N/A", "security_attributes": ["dept_eng", "level_restricted"] }
{ "index": { "_index": "documents", "_id": "5" } }
{ "title": "Sales Pipeline Q3", "department": "sales", "classification": "internal", "owner": "sales-team", "salary_info": "N/A", "security_attributes": ["dept_sales", "level_internal"] }
{ "index": { "_index": "documents", "_id": "6" } }
{ "title": "Public Press Release", "department": "sales", "classification": "public", "owner": "sales-team", "salary_info": "N/A", "security_attributes": ["dept_sales", "level_public"] }
'
echo ""

echo "3. Refreshing the index..."
lucenia_curl -X POST "$LUCENIA_URL/documents/_refresh"
echo ""

echo "=== Data setup complete ==="
echo "Loaded 6 documents across departments: hr, engineering, sales"
echo "Next: run ./scripts/setup_rbac.sh and ./scripts/setup_abac.sh"
