# Index State Management (ISM) Tutorial

This tutorial demonstrates how to use Lucenia's Index State Management (ISM) plugin to automate index lifecycle operations. ISM enables you to define policies that automatically manage indexes based on age, size, or document count - eliminating manual maintenance tasks.

## What You'll Learn

- Create ISM policies with states, actions, and transitions
- Apply policies to indexes manually and automatically via templates
- Monitor managed index status
- Implement common patterns: log rotation, hot-warm-delete workflows

## Prerequisites

- Docker and Docker Compose V2
- A valid Lucenia license file (`trial.crt`)

## Getting Started

### 1. Clone and Setup

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git
cd lucenia-tutorials/8_ism
source env.sh
```

### 2. Add Your License

Copy your Lucenia license to the config directory:

```bash
cp ~/Downloads/trial.crt node/config/
```

### 3. Start the Cluster

```bash
docker compose up -d
```

### 4. Verify the Cluster

```bash
curl -X GET https://localhost:9200/_cluster/health?pretty \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

## Understanding ISM Policies

An ISM policy defines how indexes should be managed over their lifecycle. Each policy contains:

- **States**: Named stages an index can be in (e.g., "hot", "warm", "delete")
- **Actions**: Operations performed when entering a state (e.g., rollover, force_merge, delete)
- **Transitions**: Conditions that move an index between states (e.g., age > 30 days)

## Tutorial: Create a Log Retention Policy

Let's create a policy that manages log indexes through their lifecycle:
1. **Hot**: Active indexes receiving writes
2. **Warm**: Read-only indexes with reduced replicas
3. **Delete**: Indexes past retention period are removed

### Step 1: Create the ISM Policy

```bash
curl -X PUT "https://localhost:9200/_plugins/_ism/policies/log_retention_policy" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
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
```

This policy will:
- Automatically apply to any index matching `logs-*`
- Rollover indexes after 1 day or when they reach 10GB
- Move to warm state after 2 days (read-only, 0 replicas)
- Delete indexes after 7 days

### Step 2: Verify the Policy

```bash
curl -X GET "https://localhost:9200/_plugins/_ism/policies/log_retention_policy?pretty" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

### Step 3: Create a Test Index

Create an index that matches the policy pattern:

```bash
# Create the initial index with an alias for rollover
curl -X PUT "https://localhost:9200/logs-000001" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "aliases": {
    "logs": {
      "is_write_index": true
    }
  }
}'
```

### Step 4: Add Sample Data

```bash
curl -X POST "https://localhost:9200/logs/_doc" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "level": "INFO",
  "message": "Application started successfully",
  "service": "api-gateway"
}'

curl -X POST "https://localhost:9200/logs/_doc" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "level": "ERROR",
  "message": "Connection timeout to database",
  "service": "user-service"
}'
```

### Step 5: Check Managed Index Status

The ISM plugin runs every 5 minutes by default. Check the status of your managed index:

```bash
curl -X GET "https://localhost:9200/_plugins/_ism/explain/logs-000001?pretty" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

To see the full policy attached to the index:

```bash
curl -X GET "https://localhost:9200/_plugins/_ism/explain/logs-000001?show_policy=true&pretty" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

## Manual Policy Management

### Apply a Policy to an Existing Index

If you have an index that wasn't auto-matched by a template:

```bash
# Create a standalone index
curl -X PUT "https://localhost:9200/my-data-index" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD

# Attach the policy manually
curl -X POST "https://localhost:9200/_plugins/_ism/add/my-data-index" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "policy_id": "log_retention_policy"
}'
```

### Remove a Policy from an Index

```bash
curl -X POST "https://localhost:9200/_plugins/_ism/remove/my-data-index" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

### Change the Policy on a Managed Index

```bash
curl -X POST "https://localhost:9200/_plugins/_ism/change_policy/logs-*" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "policy_id": "new_policy_name",
  "state": "hot"
}'
```

## Example: Simple Delete Policy

A minimal policy that deletes indexes after 30 days:

```bash
curl -X PUT "https://localhost:9200/_plugins/_ism/policies/simple_delete_policy" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "policy": {
    "description": "Delete indexes after 30 days",
    "default_state": "active",
    "states": [
      {
        "name": "active",
        "actions": [],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": {
              "min_index_age": "30d"
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
    ]
  }
}'
```

## Example: Force Merge Policy

Optimize indexes by reducing segments after they stop receiving writes:

```bash
curl -X PUT "https://localhost:9200/_plugins/_ism/policies/force_merge_policy" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "policy": {
    "description": "Force merge old indexes to 1 segment",
    "default_state": "active",
    "states": [
      {
        "name": "active",
        "actions": [],
        "transitions": [
          {
            "state_name": "merge",
            "conditions": {
              "min_index_age": "7d"
            }
          }
        ]
      },
      {
        "name": "merge",
        "actions": [
          {
            "read_only": {}
          },
          {
            "force_merge": {
              "max_num_segments": 1
            }
          }
        ],
        "transitions": []
      }
    ]
  }
}'
```

## List All Policies

```bash
curl -X GET "https://localhost:9200/_plugins/_ism/policies?pretty" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

## Delete a Policy

```bash
curl -X DELETE "https://localhost:9200/_plugins/_ism/policies/simple_delete_policy" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

## Retry Failed Actions

If an ISM action fails, you can retry it:

```bash
curl -X POST "https://localhost:9200/_plugins/_ism/retry/logs-*" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "state": "hot"
}'
```

## Using OpenSearch Dashboards

You can also manage ISM policies through the Dashboards UI:

1. Navigate to http://localhost:5601
2. Login with `admin` / `MyStrongPassword123!`
3. Go to **Index Management** > **State management policies**
4. Create, edit, and monitor policies visually

## Available ISM Actions

| Action | Description |
|--------|-------------|
| `rollover` | Roll over to a new index based on age, size, or doc count |
| `delete` | Delete the managed index |
| `read_only` | Set index to read-only |
| `read_write` | Set index to read-write |
| `replica_count` | Change the number of replicas |
| `force_merge` | Merge segments to reduce count |
| `shrink` | Reduce primary shard count |
| `close` | Close the index |
| `open` | Open a closed index |
| `snapshot` | Take a snapshot of the index |
| `index_priority` | Set index recovery priority |
| `allocation` | Move index to specific nodes |
| `notification` | Send alerts via Slack, Chime, or webhook |

## Transition Conditions

| Condition | Description | Example |
|-----------|-------------|---------|
| `min_index_age` | Time since index creation | `"30d"`, `"12h"` |
| `min_rollover_age` | Time since last rollover | `"7d"` |
| `min_doc_count` | Minimum document count | `1000000` |
| `min_size` | Minimum index size | `"50gb"` |
| `cron` | Scheduled time | See cron syntax |

## Cleanup

Stop and remove containers:

```bash
docker compose down
```

To also remove the data volume:

```bash
docker compose down -v
```

## Next Steps

- Explore the [ISM API documentation](https://docs.lucenia.io/im-plugin/ism/api/)
- Learn about [ISM error notifications](https://docs.lucenia.io/im-plugin/ism/policies/#error-notifications)
- Set up [snapshot repositories](https://docs.lucenia.io/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/) for backup actions
