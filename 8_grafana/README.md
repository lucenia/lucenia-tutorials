
# Lucenia with Grafana and FluentBit

In this tutorial you'll set up a logging and metrics pipeline
complete with collection, storage, search, and visualization.
To do this, we will use Lucenia with FluentBit for collection
and Grafana for visualization.  At the end of this tutorial
you will have containers collecting logs and metrics from your
system with a dashboard to easily search, view, and gain
insights.

## Prerequisites

Before we begin, make sure you have the following prerequisites:

- Docker and Docker Compose V2

Clone the lucenia-tutorials repository, then navigate to the
8_grafana directory and set up your local environment:

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git && cd lucenia-tutorials/8_grafana
```

### Obtain a Lucenia Product License

Navigate to [Lucenia's website](https://lucenia.io), and click
`Try Lucenia`. Follow the steps to obtain your license, and save
it to a file named `trial.crt` inside the `8_grafana` tutorial
directory.

## Step 1: Grafana Datasource Configuration

In the tutorial directory the Grafana datasource config is
already present, but if you didn't already have this file,
here is how you could create it:

```yaml
apiVersion: 1

# Grafana takes this yaml list to define
# preconfigured datasources.  This is a
# very convenient and replicable way of
# specifying Grafana's connection to Lucenia.
datasources:
  - name: Lucenia

    # Lucenia's API is compatible with OpenSearch 2.14.0
    type: grafana-opensearch-datasource
    access: proxy

    # Ensure this matches your Lucenia node's details
    # For our docker-compose.yml, Lucnia's host is "lucenia-node"
    url: https://lucenia-node:9200
    basicAuth: true
    basicAuthUser: admin
    secureJsonData:
      # In production this needs to be specified securely.
      basicAuthPassword: MyStrongPassword123_
    jsonData:
      flavor: "opensearch"
      # Do not change this version field
      # This tells Grafana what API version is
      # compatible with Lucenia.
      # See https://docs.lucenia.io/troubleshoot/unsupported-product
      version: "2.14.0"
      timeField: "@timestamp"
      
      # TLS verification is skipped in the tutorial
      #tlsSkipVerify: true

      # This selects which indices to use in Grafana dashboards
      # In this case we care about the fluentbit indices, as
      # that's where our logs and metrics are.
      database: "fluentbit-*"
    isDefault: true
```

## Step 2: Add Grafana to Docker Compose

In previous tutorials (see `1_getting-started` and others) Lucenia has been
configured in docker compose, and here we'll build from there.  We'll end up
with three containers - one for Lucenia, one for Grafana, and one for FluentBit.
Next we'll add the one for Grafana.

For your config to work, it must:
- Install the `grafana-opensearch-datasource` plugin
- Properly mount the datasource config
- Handle port forwarding

Here's how you can do it, with detailed comments:

```yaml
name: lucenia
services:
  lucenia-node:
    ...

  grafana:
    # Tutorial tested with this version,
    # check for the latest version after
    # getting this version working.
    image: grafana/grafana:12.2
    container_name: grafana
    ports:
      - "3000:3000"
    expose:
      - "3000"
    environment:
      # We need to install the opensearch plugin
      # for Grafana to connect to Lucenia
      - GF_INSTALL_PLUGINS=grafana-opensearch-datasource

      # Tell Grafana where our datasource configs can be found
      - GF_PATHS_PROVISIONING=/etc/grafana/provisioning
    volumes:
      # Mount the datasource you created
      # in step 1 inside the container
      - ./grafana-datasource.yaml:/etc/grafana/provisioning/datasources/opensearch.yml
    networks:
      - lucenia-net
```

## Step 3: Add the FluentBit container in Docker Compose

Once Grafana is added to the `docker-compose.yml` file, we next
need to add the container for FluentBit.  We won't go in-depth
on configuring FluentBit pipelines, but there are two included
configs you may use or reference:
- `fluent-bit.yaml` - Basic-ish config with metrics and logs, but
  still rather useful
- `fluent-bit-advanced.yaml` - Includes filters, parsers, more
  specialized indices.  Comprehensive.

For a little more information on the FluentBit configurations,
see the tutorial `7_logging`.

You can use these sample FluentBit pipelines in your
`docker-compose.yml` file.  For FluentBit to have access to
the host machine's log files, we need to mount the log
directory in docker-compose.  We also need to mount
the configuration files (main config file plus the
scripts in the `scripts` directory).  Lastly you need to
specify the log path as a CLI argument.

```yaml
name: lucenia
services:
  lucenia-node:
    ...
  grafana:
    ...
  fluent-bit:
    image: fluent/fluent-bit:4.0.7
    container_name: fluent-bit
    volumes:
      # Mount the FluentBit config - change this to match
      # your config file (either of the samples or your own)
      - ./fluent-bit-advanced.yaml:/fluent-bit/etc/fluent-bit.yaml
      # Scripts are used for cleaning and enriching the
      # logs in more flexible ways
      - ./scripts:/fluent-bit/scripts
      # Grant access to host system's log files
      - /var/log:/var/log

    # We are using YAML for configuration because it is more modern,
    # but this means we need to set the config file path
    # as a command line argument.
    command: /fluent-bit/bin/fluent-bit -c /fluent-bit/etc/fluent-bit.yaml
    networks:
      - lucenia-net
```

## Step 4: Start Services with Docker Compose

Use the following command to set up a Lucenia cluster, FluentBit, and Grafana:

```bash
docker compose up -d
```

This command will start up the services you specified in
the `docker-compose.yml` file:
- **Lucenia Search**: Search engine to handle our log data.
- **FluentBit**: A log processor to collect and enhance our logs, then send to Lucenia Search.
- **Grafana**: A tool visualize and our log data.

### Confirm the Services are Running

Confirm the Lucenia cluster is running and healthy:

```bash
curl -X GET https://localhost:9200 -ku admin:MyStrongPassword123_
curl -X GET https://localhost:9200/_cluster/health?pretty -ku admin:MyStrongPassword123_
```

## Step 5: Open Grafana and Explore Logs

Navigate to Grafana at `http://localhost:3000` and log in
with the credentials `admin` and `admin`, set an admin
password, then click "Explore" on the left-hand side
of the page.  You should see some query options and below
that a chart (potentially empty).  To fill the chart,
generate some test logs:

```bash
echo "$(date) ERROR: Test-This is an error message" | sudo tee -a /var/log/luceniademo.log
echo "$(date) INFO: Test-Application started successfully" | sudo tee -a /var/log/luceniademo.log
echo "$(date) WARNING: Test-High memory usage detected" | sudo tee -a /var/log/luceniademo.log
```

Then select the "Logs" option near the middle of the page,
and click "Run query" in the top right.  You should see the
chart populate with a bar chart of log frequency over time,
with the test logs shown below.  This confirms the pipeline
is working!  There should also be a lot of entries for
system metrics like CPU and memory usage.

## Step 6: Create a Grafana Dashboard

1. On the left side of the page, click "Dashboards", then click
   "+ Create dashboard"
2. Click "+ Add visualization" then select Lucenia as the
   datasource.  We'll create a basic dashboard for CPU usage
3. On the bottom of the page, ensure the "Metric" data type
   is selected
4. Change "count", which simply counts messages, to "Average"
   by clicking on "Count"
5. Where it says "Select Field", select "cpu_p" (you may need to scroll)
6. Click "Refresh" in the upper-right - the chart should populate
   with CPU usage
7. Change the title in the upper-right, then click "Back to dashboard"
   to see your basic CPU usage dashboard

Now you have created a Grafana dashboard to view your system metrics!
Dashboards can also be created to view logs and log metrics, other
system metrics, and more.







