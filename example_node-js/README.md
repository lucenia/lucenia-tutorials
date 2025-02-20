# OpenSearch Client connecting to Lucenia

This TypeScript project demonstrates how to interact with Lucenia using the official OpenSearch Node.js client. It shows basic CRUD operations for both indices and documents.

## Prerequisites

- Node.js
- Lucenia instance running on localhost:9200
- Basic understanding of Lucenia concepts

## Setup

1. Install dependencies:

```bash
npm install
```

2. Configure Lucenia connection in index.ts:

```typescript
const client = new opensearch.Client({
  node: 'https://localhost:9200',
  auth: {
    username: 'admin',
    password: 'myStrongPassword@123',
  },
  ssl: {
    rejectUnauthorized: false,
  },
});
```

## Features Demonstrated

The sample code demonstrates:

- Creating an Lucenia index with custom settings
- Checking if an index exists
- Adding documents to an index
- Searching documents using match query
- Deleting documents
- Deleting indices
- Proper client cleanup

## Running the Example

```bash
npx ts-node src/index.ts
```

## Index Configuration

The example creates an index named 'books' with the following settings:

- 4 shards
- 3 replicas

## Security Note

The example includes SSL verification disabled (`rejectUnauthorized: false`). In production environments, proper SSL configuration should be implemented.

## Dependencies

- [@opensearch-project/opensearch](https://www.npmjs.com/package/@opensearch-project/opensearch): ^3.3.0
- TypeScript: ^5.7.3
