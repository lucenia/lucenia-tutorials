# Seamless Data Migration: From OpenSearch to Lucenia

This tutorial will guide you through the process of migrating your data from OpenSearch to Lucenia Search. We start by setting up a new OpenSearch cluster using docker compose, and then migrate from OpenSearch to Lucenia Search.

## Prerequisites

Before we begin, make sure you have the following prerequisites:

- Docker and Docker Compose V2

Clone the lucenia-tutorials repository, then navigate to the 6_migration directory and setup your local environment:

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git && cd lucenia-tutorials/6_migration && source env.sh
```

## Step 1: Create an OpenSearch Cluster

Use the following command to setup an OpenSearch cluster:

```bash
docker compose --file docker-compose-setup.yml up -d
```

Confirm the cluster is up and running and check its health:

```bash
curl -X GET https://localhost:9200 -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

We have an OpenSearch cluster at version `2.18.0` with Lucene `9.12.0`.

```bash
curl -X GET https://localhost:9200/_cluster/health?pretty -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

Our three node cluster health should be `green`. Now, it is time to prepare for the migration.

## Step 2: Prepare for Migration from OpenSearch to Lucenia Search

Since we are running our OpenSearch cluster with docker compose, we will essentially perform a full cluster restart. We will update our docker compose file to use Lucenia Search instead of OpenSearch, and make a few modifications to our configuration to ensure a seamless migration.

### Add Sample Data

Of course for any successful migration, we need data to ensure our search engine is working as expected. Let's add some sample data to our OpenSearch cluster.

```bash
curl -X POST https://localhost:9200/movies/_doc/1 -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD -H 'Content-Type: application/json' -d '
{
    "title": "Migration",
    "year": 2023
}
'
```

We can see our new index is created:

```bash
curl -X GET https://localhost:9200/_cat/indices -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

And confirm the data is added by querying the index:

```bash
curl -X GET https://localhost:9200/movies/_search -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

### Obtain a Lucenia Search License

Navigate to [Lucenia's website](https://lucenia.io), and click `Try Lucenia`. Follow the steps to obtain your license, and save it to a file named `trial.crt` in this tutorial directory.

### Update our Docker Compose File

We have a new docker compose file with all necessary changes to use Lucenia Search, [docker-compose-lucenia.yml](docker-compose-lucenia.yml). 

Note the changes include modifications for each node including a new image, `lucenia/lucenia:0.2.1`, and environment updates. We ensure we set the license filepath as well as point our data path to the existing data.

```yaml
- plugins.license.certificate_filepath=config/trial.crt
- path.data=/usr/share/opensearch/data
- "LUCENIA_JAVA_OPTS=-Xms512m -Xmx512m"
- LUCENIA_INITIAL_ADMIN_PASSWORD=${LUCENIA_INITIAL_ADMIN_PASSWORD}
```

And, the addition of the license file to the `volumes` section:

```yaml
- ./trial.crt:/usr/share/lucenia/config/trial.crt
```

## Step 3: Migrate from OpenSearch to Lucenia Search

Now that we have our OpenSearch cluster running with sample data, and our Lucenia Search cluster setup, we can begin the migration process.

### Disable Shard Allocation

First, we need to disable shard allocation on our OpenSearch cluster:

```bash
curl -X PUT https://localhost:9200/_cluster/settings -ku admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD -H 'Content-Type: application/json' -d '
{
    "persistent": {
        "cluster.routing.allocation.enable": "none"
    }
}
'
```

### Restart the Cluster

Now, we can restart our OpenSearch cluster with Lucenia Search by pulling the new image and restarting the cluster:

```bash
docker compose  --file docker-compose-lucenia.yml pull
docker compose --file docker-compose-lucenia.yml up -d
```

Confirm the Lucenia cluster is running and healthy:

```bash
curl -X GET https://localhost:9200 -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
curl -X GET https://localhost:9200/_cluster/health?pretty -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

We are running a Lucenia Search cluster at version `0.2.1` with Lucene `10.0.0`!
However, our cluster health is yellow...let's look into this.

First, confirm the version for each node: `nodes.<node-id>.version` is `0.2.1` in the response.

```bash
curl -XGET https://localhost:9200/_nodes/_all?pretty -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

Let's check the health of our indices:

```bash
curl -XGET https://localhost:9200/_cat/indices?v -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

Our indices are yellow, let's take a look at our shards:

```bash
curl -XGET https://localhost:9200/_cat/shards?v -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

Our replica shards are `UNASSIGNED`. We need to enable shard allocation and allow the cluster to recover:

```bash
curl -X PUT https://localhost:9200/_cluster/settings -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD -H 'Content-Type: application/json' -d'
{
    "persistent": {
        "cluster.routing.allocation.enable": "all"
    }
}
'
```

We see an error in the response regarding an unknown cluster setting. To get past this error, we need to set the `archived.plugins.index_state_management.template_migration.control` setting to null.

```bash
curl -X PUT https://localhost:9200/_cluster/settings -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD -H 'Content-Type: application/json' -d'
{
    "persistent": {
        "archived.plugins.index_state_management.template_migration.control": null
    }
}
'
```


Now, re-enable shard allocation.

```bash
curl -X PUT https://localhost:9200/_cluster/settings -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD -H 'Content-Type: application/json' -d'
{
    "persistent": {
        "cluster.routing.allocation.enable": "all"
    }
}
'
```

Let's check the cluster health and the indices again.

```bash
curl -XGET https://localhost:9200/_cat/indices?pretty -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
curl -XGET https://localhost:9200/_cluster/health?pretty -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

Our indices and cluster health are now green! One last confirmation...let's query our index:

```bash
curl -X GET https://localhost:9200/movies/_search -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

We have successfully migrated from OpenSearch 2.18.0 to Lucenia Search 0.2.1. Our data is intact and our cluster is healthy. If you are considering moving to Lucenia from your current search engine, this tutorial provides a comprehensive guide to help you through the process. For additional details on Lucenia Search, check out the [Lucenia documentation](https://docs.lucenia.io/about).
