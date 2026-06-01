#!/usr/bin/env python

"""
Lucenia Python Client Tutorial

Demonstrates connecting to Lucenia, creating an index, indexing documents
(single and bulk), searching, and cleanup using the lucenia-py client.
"""

import os

from lucenia import Lucenia, helpers


def main() -> None:
    host = os.getenv("LUCENIA_HOST", "localhost")
    port = int(os.getenv("LUCENIA_PORT", "9200"))
    user = os.getenv("LUCENIA_USER", "admin")
    password = os.getenv("LUCENIA_PASSWORD", "MyStrongPassword123!")

    # -- 1. Create the client --
    print("=== Creating Lucenia client ===")

    client = Lucenia(
        hosts=[{"host": host, "port": port}],
        http_auth=(user, password),
        use_ssl=True,
        verify_certs=False,
        ssl_show_warn=False,
    )

    info = client.info()
    print(f"Connected to {info['version']['distribution']} {info['version']['number']}")

    # -- 2. Create an index --
    index_name = "python-tutorial-index"

    if client.indices.exists(index_name):
        print(f"Index '{index_name}' already exists, deleting it first...")
        client.indices.delete(index_name)

    print(f"\n=== Creating index: {index_name} ===")
    index_body = {
        "settings": {
            "index": {
                "number_of_shards": 1,
                "number_of_replicas": 0,
            }
        },
        "mappings": {
            "properties": {
                "title": {"type": "text"},
                "text": {"type": "text"},
                "year": {"type": "integer"},
            }
        },
    }
    response = client.indices.create(index_name, body=index_body)
    print(f"Index created: {response['acknowledged']}")

    # -- 3. Index a single document --
    print("\n=== Indexing a single document ===")
    doc1 = {
        "title": "Introduction to Lucenia",
        "text": "Lucenia is a high-performance search engine.",
        "year": 2025,
    }
    response = client.index(index=index_name, body=doc1, id="1", refresh=True)
    print(f"Indexed document 1: {response['result']}")

    # -- 4. Bulk index documents --
    print("\n=== Bulk indexing documents ===")
    actions = [
        {
            "_index": index_name,
            "_id": "2",
            "_source": {
                "title": "Getting Started with Python",
                "text": "Use the lucenia-py client to connect.",
                "year": 2025,
            },
        },
        {
            "_index": index_name,
            "_id": "3",
            "_source": {
                "title": "Search Features",
                "text": "Full-text search, aggregations, and more.",
                "year": 2025,
            },
        },
        {
            "_index": index_name,
            "_id": "4",
            "_source": {
                "title": "Bulk Operations",
                "text": "Efficiently index many documents at once.",
                "year": 2025,
            },
        },
    ]
    success_count, errors = helpers.bulk(client, actions)
    print(f"Bulk indexed {success_count} documents (errors: {errors})")

    # Refresh so documents are searchable
    client.indices.refresh(index=index_name)

    # -- 5. Search all documents --
    print("\n=== Search: match all ===")
    response = client.search(index=index_name, body={"query": {"match_all": {}}})
    hits = response["hits"]["hits"]
    print(f"Found {response['hits']['total']['value']} documents:")
    for hit in hits:
        print(f"  [{hit['_id']}] {hit['_source']['title']}")

    # -- 6. Search with a match query --
    print("\n=== Search: match query for 'Lucenia' ===")
    query = {
        "query": {
            "match": {
                "title": "Lucenia",
            }
        }
    }
    response = client.search(index=index_name, body=query)
    hits = response["hits"]["hits"]
    print(f"Found {response['hits']['total']['value']} documents:")
    for hit in hits:
        print(f"  [{hit['_id']}] score={hit['_score']:.4f} {hit['_source']['title']}")

    # -- 7. Search with a multi_match query --
    print("\n=== Search: multi_match for 'search' across title and text ===")
    query = {
        "query": {
            "multi_match": {
                "query": "search",
                "fields": ["title^2", "text"],
            }
        }
    }
    response = client.search(index=index_name, body=query)
    hits = response["hits"]["hits"]
    print(f"Found {response['hits']['total']['value']} documents:")
    for hit in hits:
        print(f"  [{hit['_id']}] score={hit['_score']:.4f} {hit['_source']['title']}")

    # -- 8. Delete a document --
    print("\n=== Deleting document id=1 ===")
    response = client.delete(index=index_name, id="1")
    print(f"Document deleted: {response['result']}")

    # -- 9. Delete the index --
    print(f"\n=== Deleting index: {index_name} ===")
    response = client.indices.delete(index=index_name)
    print(f"Index deleted: {response['acknowledged']}")

    print("\nDone!")


if __name__ == "__main__":
    main()
