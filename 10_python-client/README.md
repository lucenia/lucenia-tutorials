# Python Client Tutorial for Lucenia

This tutorial demonstrates how to use the lucenia-py client library to interact with Lucenia. It covers connecting to a cluster, creating an index, indexing documents (single and bulk), searching, and cleanup.

## Prerequisites

- Docker and Docker Compose
- Python 3.8+
- A valid Lucenia license file (`trial.crt`)

## Setup

### A. Clone the Repository

```bash
git clone git@github.com:lucenia/lucenia-tutorials && cd lucenia-tutorials/10_python-client && source env.sh
```

### B. Copy the License File

```bash
cp ~/Downloads/trial.crt node/config/
```

### C. Start Lucenia

```bash
docker compose up -d
```

Wait for the health check to pass:

```bash
curl https://localhost:9200 -u "admin:MyStrongPassword123!" --insecure
```

### D. Install Dependencies

```bash
pip install -r requirements.txt
```

Or install directly from the source repo:

```bash
pip install -e /path/to/python-client
```

## Run the Example

```bash
python lucenia_python_example.py
```

This will:

1. Connect to Lucenia at `https://localhost:9200`
2. Create an index (`python-tutorial-index`) with custom settings and mappings
3. Index a single document
4. Bulk index 3 more documents using `helpers.bulk`
5. Search all documents (match_all)
6. Search with a match query for "Lucenia"
7. Search with a multi_match query across title and text
8. Delete a document
9. Delete the index

### Environment Variables

Override connection defaults with environment variables:

| Variable           | Default                | Description       |
|--------------------|------------------------|-------------------|
| `LUCENIA_HOST`     | `localhost`            | Lucenia hostname  |
| `LUCENIA_PORT`     | `9200`                 | Lucenia port      |
| `LUCENIA_USER`     | `admin`                | Username          |
| `LUCENIA_PASSWORD` | `MyStrongPassword123!` | Password          |

## Clean Up

```bash
docker compose down -v
```

## Learn More

- [Lucenia Documentation](https://docs.lucenia.io/)
