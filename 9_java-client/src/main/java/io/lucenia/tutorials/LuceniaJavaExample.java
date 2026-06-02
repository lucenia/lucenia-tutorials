package io.lucenia.tutorials;

import io.lucenia.client.json.jackson.JacksonJsonpMapper;
import io.lucenia.client.lucenia.LuceniaClient;
import io.lucenia.client.lucenia._types.FieldValue;
import io.lucenia.client.lucenia._types.Refresh;
import io.lucenia.client.lucenia._types.mapping.IntegerNumberProperty;
import io.lucenia.client.lucenia._types.mapping.Property;
import io.lucenia.client.lucenia._types.mapping.TypeMapping;
import io.lucenia.client.lucenia.core.BulkRequest;
import io.lucenia.client.lucenia.core.BulkResponse;
import io.lucenia.client.lucenia.core.IndexRequest;
import io.lucenia.client.lucenia.core.SearchRequest;
import io.lucenia.client.lucenia.core.SearchResponse;
import io.lucenia.client.lucenia.core.bulk.BulkOperation;
import io.lucenia.client.lucenia.core.bulk.IndexOperation;
import io.lucenia.client.lucenia.indices.CreateIndexRequest;
import io.lucenia.client.lucenia.indices.DeleteIndexRequest;
import io.lucenia.client.lucenia.indices.IndexSettings;
import io.lucenia.client.transport.httpclient5.ApacheHttpClient5TransportBuilder;
import org.apache.hc.client5.http.auth.AuthScope;
import org.apache.hc.client5.http.auth.UsernamePasswordCredentials;
import org.apache.hc.client5.http.impl.auth.BasicCredentialsProvider;
import org.apache.hc.client5.http.impl.nio.PoolingAsyncClientConnectionManagerBuilder;
import org.apache.hc.client5.http.ssl.ClientTlsStrategyBuilder;
import org.apache.hc.client5.http.ssl.NoopHostnameVerifier;
import org.apache.hc.core5.http.HttpHost;
import org.apache.hc.core5.ssl.SSLContextBuilder;

import java.util.ArrayList;

public class LuceniaJavaExample {

    public static void main(String[] args) throws Exception {
        var hostname = System.getenv().getOrDefault("LUCENIA_HOST", "localhost");
        var port = Integer.parseInt(System.getenv().getOrDefault("LUCENIA_PORT", "9200"));
        var user = System.getenv().getOrDefault("LUCENIA_USER", "admin");
        var pass = System.getenv().getOrDefault("LUCENIA_PASSWORD", "MyStrongPassword123!");

        // -- 1. Create the client --
        System.out.println("=== Creating Lucenia client ===");

        var hosts = new HttpHost[]{new HttpHost("https", hostname, port)};

        var sslContext = SSLContextBuilder.create()
                .loadTrustMaterial(null, (chains, authType) -> true)
                .build();

        var transport = ApacheHttpClient5TransportBuilder.builder(hosts)
                .setMapper(new JacksonJsonpMapper())
                .setHttpClientConfigCallback(httpClientBuilder -> {
                    var credentialsProvider = new BasicCredentialsProvider();
                    for (var host : hosts) {
                        credentialsProvider.setCredentials(
                                new AuthScope(host),
                                new UsernamePasswordCredentials(user, pass.toCharArray()));
                    }

                    var tlsStrategy = ClientTlsStrategyBuilder.create()
                            .setSslContext(sslContext)
                            .setHostnameVerifier(NoopHostnameVerifier.INSTANCE)
                            .build();

                    var connectionManager = PoolingAsyncClientConnectionManagerBuilder.create()
                            .setTlsStrategy(tlsStrategy)
                            .build();

                    return httpClientBuilder
                            .setDefaultCredentialsProvider(credentialsProvider)
                            .setConnectionManager(connectionManager);
                })
                .build();

        var client = new LuceniaClient(transport);

        // Print server info
        var info = client.info();
        System.out.printf("Connected to %s version %s%n",
                info.version().distribution(), info.version().number());

        // -- 2. Create an index --
        var indexName = "java-tutorial-index";

        if (client.indices().exists(r -> r.index(indexName)).value()) {
            System.out.println("Index already exists, deleting it first...");
            client.indices().delete(new DeleteIndexRequest.Builder().index(indexName).build());
        }

        System.out.println("\n=== Creating index: " + indexName + " ===");
        IndexSettings settings = new IndexSettings.Builder()
                .numberOfShards("1")
                .numberOfReplicas("0")
                .build();
        TypeMapping mapping = new TypeMapping.Builder()
                .properties("age", new Property.Builder()
                        .integer(new IntegerNumberProperty.Builder().build())
                        .build())
                .build();
        CreateIndexRequest createIndexRequest = new CreateIndexRequest.Builder()
                .index(indexName)
                .settings(settings)
                .mappings(mapping)
                .build();
        client.indices().create(createIndexRequest);
        System.out.println("Index created successfully.");

        // -- 3. Index a single document --
        System.out.println("\n=== Indexing a single document ===");
        var doc1 = new IndexData("Introduction to Lucenia", "Lucenia is a high-performance search engine.");
        IndexRequest<IndexData> indexRequest = new IndexRequest.Builder<IndexData>()
                .index(indexName)
                .id("1")
                .document(doc1)
                .refresh(Refresh.True)
                .build();
        client.index(indexRequest);
        System.out.println("Indexed document 1: " + doc1);

        // -- 4. Bulk index documents --
        System.out.println("\n=== Bulk indexing documents ===");
        var ops = new ArrayList<BulkOperation>();
        var doc2 = new IndexData("Getting Started with Java", "Use the lucenia-java client to connect.");
        ops.add(new BulkOperation.Builder()
                .index(IndexOperation.of(io -> io.index(indexName).id("2").document(doc2)))
                .build());
        var doc3 = new IndexData("Search Features", "Full-text search, aggregations, and more.");
        ops.add(new BulkOperation.Builder()
                .index(IndexOperation.of(io -> io.index(indexName).id("3").document(doc3)))
                .build());
        var doc4 = new IndexData("Bulk Operations", "Efficiently index many documents at once.");
        ops.add(new BulkOperation.Builder()
                .index(IndexOperation.of(io -> io.index(indexName).id("4").document(doc4)))
                .build());

        BulkResponse bulkResponse = client.bulk(new BulkRequest.Builder()
                .index(indexName)
                .operations(ops)
                .refresh(Refresh.WaitFor)
                .build());
        System.out.printf("Bulk indexed %d documents (errors: %s)%n",
                bulkResponse.items().size(), bulkResponse.errors());

        // -- 5. Search all documents --
        System.out.println("\n=== Search: match all ===");
        SearchResponse<IndexData> searchResponse = client.search(
                s -> s.index(indexName), IndexData.class);
        System.out.printf("Found %d documents:%n", searchResponse.hits().total().value());
        for (var hit : searchResponse.hits().hits()) {
            System.out.printf("  [%s] %s%n", hit.id(), hit.source());
        }

        // -- 6. Search with a match query --
        System.out.println("\n=== Search: match query for 'Lucenia' ===");
        SearchRequest matchRequest = new SearchRequest.Builder()
                .index(indexName)
                .query(q -> q.match(m -> m.field("title").query(FieldValue.of("Lucenia"))))
                .build();
        searchResponse = client.search(matchRequest, IndexData.class);
        System.out.printf("Found %d documents:%n", searchResponse.hits().total().value());
        for (var hit : searchResponse.hits().hits()) {
            System.out.printf("  [%s] score=%.4f %s%n", hit.id(), hit.score(), hit.source());
        }

        // -- 7. Delete a document --
        System.out.println("\n=== Deleting document id=1 ===");
        client.delete(d -> d.index(indexName).id("1"));
        System.out.println("Document deleted.");

        // -- 8. Delete the index --
        System.out.println("\n=== Deleting index: " + indexName + " ===");
        var deleteResponse = client.indices().delete(
                new DeleteIndexRequest.Builder().index(indexName).build());
        System.out.println("Index deleted: " + deleteResponse.acknowledged());

        System.out.println("\nDone!");
    }
}
