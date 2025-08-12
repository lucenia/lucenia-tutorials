# Lucenia and FluentBit: Laying the Groundwork for Production Ready Logging

This tutorial will guide you through the process of building a log aggregation pipeline with Lucenia and FluentBit. We will start by setting up our services with docker compose, and then utilize OpenSearch Dashboards to visualize our data.

In [Part 1](https://lucenia.io/2025/07/17/fluentbit-lucenia-ai-devops/) of this series, we discussed how Lucenia and FluentBit are transforming how DevOps teams handle log management. Today, we will work with a local demo to get hands-on experience. We are building a foundation for production-grade log pipelines prepared to handle billions of events daily.

## Prerequisites

Before we begin, make sure you have the following prerequisites:

- Docker and Docker Compose V2

Clone the lucenia-tutorials repository, then navigate to the 7_logging directory and setup your local environment:

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git && cd lucenia-tutorials/7_logging && source env.sh
```

### Obtain a Lucenia Product License

Navigate to [Lucenia's website](https://lucenia.io), and click `Try Lucenia`. Follow the steps to obtain your license, and save it to a file named `trial.crt` in this tutorial directory.

## Step 1: Start Up our Services

### Services Overview

The files needed to run our services include configuration files for docker compose, FluentBit, and OpenSearch Dashboards.

**docker-compose.yml**

We define our services we will run in a docker compose file.

**fluent-bit.conf**

The FluentBit configuration file contains configuration for logging input, output and a filter.

**opensearch_dashboards.yml**

Finally, OpenSearch Dashboards configuration defines and ensures connection to Lucenia.

### Start the Services

Use the following command to setup a Lucenia cluster, FluentBit, and OpenSearch Dashboards:

```bash
docker compose up -d
```

### What is Happening?

This command will start up the following services:
- **Lucenia Search**: Search engine to handle our log data.
- **FluentBit**: A log processor to collect and enhance our logs, then send to Lucenia Search.
- **OpenSearch Dashboards**: A tool visualize and our log data.

FluentBit is configured to collect logs from the `/var/log` directory (from files named *.log), process them, and send them to Lucenia Search. Notice the `[FILTER]` section. This is how we instruct FluentBit to enrich each log entry with metadata – environment, team, service, and version. In production, you'd pull these from environment variables or service discovery, but we hardcode them for simplicty and to demonstrate the concept.

Our output defined in the Fluent Bit configuration matches on '*', meaning all logs will be sent to Lucenia Search to the `docker-logs` index. We define all the connection and authentication details here as well so that Fluent Bit and OpenSearch Dashboards can communicate with Lucenia.

### Confirm the Services are Running

Confirm the Lucenia cluster is running and healthy:

```bash
curl -X GET https://localhost:9200 -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
curl -X GET https://localhost:9200/_cluster/health?pretty -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

Navigate to OpenSearch Dashboards at `http://localhost:5601` and log in with the credentials `admin` and `MyStrongPassword123_`. You should see the OpenSearch Dashboards interface.

## Step 2: Generate Logs

There will be logs from your machine collected and forwarded. Here, we also generate some test logs to simulate application activity and work with these logs in OpenSearch Dashboards.

Next, generate some test logs:
```bash
echo "$(date) ERROR: Test-This is an error message" | sudo tee -a /var/log/luceniademo.log
echo "$(date) INFO: Test-Application started successfully" | sudo tee -a /var/log/luceniademo.log
echo "$(date) WARNING: Test-High memory usage detected" | sudo tee -a /var/log/luceniademo.log
```

## Step 3: Visualize Logs in OpenSearch Dashboards

Navigate to http://localhost:5601 in your browser. Login with:
- Username: `admin`
- Password: `MyStrongPassword123_`

Once Authenticated, follow these steps to create an index pattern for your logs:
1. Go to `Discover` → `Index patterns`
2. Click `+ Create index pattern`, and fill in `docker-logs*` for the name, click `Next step`
3. Select `@timestamp` as the time field, click `Create index pattern`
4. Navigate to `Discover` to see your logs flowing in real-time

Notice each log entry contains the metadata we added: environment, team, service, and version. This enables filtering and analyzing logs, and is vital in when working with multiple services in many environments.

Take a look at the available fields in the left sidebar. You can filter logs by these fields to quickly drill down to environment or service-specific logs. Here our environment is `demo` and service is `fluent-bit-demo`. Think about how impactful this would be when you are running hudnreds of services and investigating an issue in one of your production environments.

## Explore Further

Now than you have a working pipeline, try experimenting with other configurations available with Fluent Bit.

You can add parsers, filters, and collect data from multiple inputs. Take this tutorial as a starting point and adapt it to your needs.

## Conclusion

In just a few minutes, you've created a working log aggregation pipeline. FluentBit's simplicity combined with Lucenia's power gives you enterprise-grade capabilities without enterprise-grade complexity.

Ready to process billions of events? You've already taken the first step.