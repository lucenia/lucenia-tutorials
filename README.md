# Lucenia Tutorials

A comprehensive collection of tutorials and example projects demonstrating how to use Lucenia Search effectively. Each tutorial is designed to be self-contained and can be run independently using Docker containers.

## Prerequisites

Before starting with any tutorial, ensure you have:

- Docker and Docker Compose V2 installed
- A valid Lucenia license file (`trial.crt`) - obtain from [Lucenia's website](https://lucenia.io)
- Git installed
- Basic knowledge of search engines and APIs

## Quick Start

```bash
# Clone the repository
git clone git@github.com:lucenia/lucenia-tutorials.git

# Navigate to desired tutorial (e.g., getting started)
cd lucenia-tutorials/1_getting-started

# Set up environment variables
source env.sh

# Copy your license file
cp ~/Downloads/trial.crt node/config/

# Start the container
docker compose up
```

## Tutorial Structure

### 1. Getting Started with Lucenia Core

**Purpose**: Basic setup and configuration of a Lucenia Search node

- Single-node cluster setup
- Basic health checks and monitoring
- Configuration best practices
- Security setup and authentication

[Get started with core →](1_getting-started/README.md)

### 2. STAC Catalog API

**Purpose**: Build a STAC-compliant API using Lucenia Search

- FastAPI integration
- STAC endpoint implementation
- Geospatial search capabilities
- Sample data loading

[Build a STAC API →](2_stac-demo/README.md)

### 3. Python Client

**Purpose**: Learn to interact with Lucenia using Python

- Basic CRUD operations
- Search queries and filtering
- Aggregations
- Bulk operations
- Error handling

[Python integration guide →](3_python-client/README.md)

### 4. Ellipse Demo

**Purpose**: Advanced geospatial search capabilities

- Complex geometric queries
- Spatial indexing
- Performance optimization
- Real-world use cases

[Explore geospatial features →](4_ellipse-demo/README.md)

### 5. Document Ingest

**Purpose**: Document processing and search implementation

- Multi-node cluster configuration
- Ingest pipeline setup
- Document processing
- Search optimization

[Document processing guide →](5_document-ingest/README.md)

### 6. Migration Guide

**Purpose**: Migrate from OpenSearch to Lucenia

- Step-by-step migration process
- Data validation
- Configuration mapping
- Best practices

[Migration guide →](6_migration/README.md)

## Example Applications

Complete example applications demonstrating real-world implementations:

- **Java Application**: Enterprise search implementation
  - [View Java example →](example_java/)
- **Node.js Application**: Modern web application integration
  - [View Node.js example →](example_node-js/)

## Development Setup

Each tutorial includes Docker Compose configurations for consistent environments:

```bash
# Navigate to specific tutorial
cd <tutorial-directory>

# Set up environment
source env.sh

# Start containers
docker compose up
```

## Security Notes

- Default credentials: `admin/MyStrongPassword123!`
- **Important**: Change default passwords in production
- Keep your license file secure
- Follow security best practices in production deployments

## Additional Resources

- [Official Documentation](https://docs.lucenia.io)
- [Lucenia Community](https://lucenia.io/community/)

## Contributing

While this is a closed-source project, we welcome feedback and issue reports through official channels.

## License

This software is licensed under proprietary terms. Contact Lucenia for licensing information.

---

For support, contact: support@lucenia.io
