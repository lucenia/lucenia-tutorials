#!/bin/bash
# ISM Demo Setup Script
# This script creates sample policies and indexes to demonstrate ISM functionality

set -e

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword@123!}"
CURL_OPTS="-ks"

echo "=== Lucenia ISM Demo Setup ==="
echo ""

# Function to make authenticated requests
lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

# Check cluster health
echo "1. Checking cluster health..."
lucenia_curl -X GET "$LUCENIA_URL/_cluster/health?pretty"
echo ""

# Create the log retention policy
echo "2. Creating log retention policy..."
lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_ism/policies/log_retention_policy" \
  -H 'Content-Type: application/json' \
  -d '{
  "policy": {
    "description": "Log retention policy: hot -> warm -> delete",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          {
            "rollover": {
              "min_index_age": "1d",
              "min_primary_shard_size": "10gb"
            }
          }
        ],
        "transitions": [
          {
            "state_name": "warm",
            "conditions": {
              "min_index_age": "2d"
            }
          }
        ]
      },
      {
        "name": "warm",
        "actions": [
          {
            "read_only": {}
          },
          {
            "replica_count": {
              "number_of_replicas": 0
            }
          }
        ],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": {
              "min_index_age": "7d"
            }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [
          {
            "delete": {}
          }
        ],
        "transitions": []
      }
    ],
    "ism_template": {
      "index_patterns": ["logs-*"],
      "priority": 100
    }
  }
}'
echo ""

# Create initial log index with alias
echo "3. Creating initial log index with alias..."
lucenia_curl -X PUT "$LUCENIA_URL/logs-000001" \
  -H 'Content-Type: application/json' \
  -d '{
  "settings": {
    "index.plugins.index_state_management.rollover_alias": "logs"
  },
  "aliases": {
    "logs": {
      "is_write_index": true
    }
  }
}'
echo ""

# Add sample documents
echo "4. Adding sample log documents..."
for i in {1..5}; do
    LEVEL=$([ $((i % 3)) -eq 0 ] && echo "ERROR" || ([ $((i % 2)) -eq 0 ] && echo "WARN" || echo "INFO"))
    lucenia_curl -X POST "$LUCENIA_URL/logs/_doc" \
      -H 'Content-Type: application/json' \
      -d "{
      \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"level\": \"$LEVEL\",
      \"message\": \"Sample log message $i\",
      \"service\": \"demo-service\"
    }"
    echo ""
done

# Check managed index status
echo "5. Checking managed index status..."
lucenia_curl -X GET "$LUCENIA_URL/_plugins/_ism/explain/logs-000001?pretty"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Your ISM demo environment is ready!"
echo "- Policy 'log_retention_policy' has been created"
echo "- Index 'logs-000001' has been created with 5 sample documents"
echo "- The index is managed by ISM (check status above)"
echo ""
echo "ISM runs every 5 minutes. Run this command to check status:"
echo "  ./scripts/check_ism_status.sh"
