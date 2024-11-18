## Getting Started

Follow these steps to get Lucenia up and running:

### A. Clone the Repository

Clone the `lucenia-tutorials` repository and set the required environment variables:

```bash
git clone git@github.com:lucenia/lucenia-tutorials && cd lucenia-tutorials/1_getting-started && source env.sh
```

*Note: If composite commands fail, run each command individually.*

### B. Copy the License File

Move the downloaded Lucenia license to the node config directory:

```bash
cp ~/Downloads/trial.crt node/config
```

*Warning: If Docker creates a `trial.crt/` directory, remove it and recopy the license file.*

### C. Launch Lucenia

Spin up the Lucenia node with Docker Compose:

```bash
docker compose up
```

This command pulls the `0.2.1` image and launches a production-ready node with a 512MB heap. Modify the `docker-compose.yml` file as needed.

### Verify the Node

Ensure the node is running:

```bash
curl https://localhost:9200 -XGET -u "admin:${LUCENIA_INITIAL_ADMIN_PASSWORD}" --insecure
```

For more information, refer to the Lucenia documentation.
