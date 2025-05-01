from opensearchpy import OpenSearch

client = OpenSearch(
   hosts=[{"host": "localhost", "port": 9200}],
   http_compress=True,
   http_auth=("admin", "MyStrongPassword123!"),
   use_ssl=True,
   verify_certs=False,
   ssl_assert_hostname=False,
   ssl_show_warn=False,
)

index_name = "test-index"

if client.indices.exists(index=index_name):
  client.indices.delete(index=index_name)

client.indices.create(index=index_name)

client.index(
   index=index_name,
   body={
      "title": "Test Document",
      "content": "This is a test document.",
   },
   id=1,
   refresh=True,
)

docs = client.search(
   index=index_name,
   body={
      "query": {
         "match": {
            "title": {
                "query": "Test Document",
            }
         },
      },
   },
)

for doc in docs["hits"]["hits"]:
   print(doc["_source"])