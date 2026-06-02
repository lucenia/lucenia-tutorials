package io.lucenia.tutorials;

import io.lucenia.client.json.jackson.JacksonJsonpMapper;
import io.lucenia.client.lucenia.LuceniaClient;
import io.lucenia.client.lucenia.core.IndexRequest;
import io.lucenia.client.lucenia.indices.CreateIndexRequest;
import io.lucenia.client.lucenia.indices.DeleteIndexRequest;
import io.lucenia.client.lucenia.indices.DeleteIndexResponse;
import io.lucenia.client.lucenia.indices.IndexSettings;
import io.lucenia.client.lucenia.indices.PutIndicesSettingsRequest;
import io.lucenia.client.transport.httpclient5.ApacheHttpClient5TransportBuilder;
import org.apache.hc.client5.http.auth.AuthScope;
import org.apache.hc.client5.http.auth.UsernamePasswordCredentials;
import org.apache.hc.client5.http.impl.auth.BasicCredentialsProvider;
import org.apache.hc.client5.http.impl.nio.PoolingAsyncClientConnectionManagerBuilder;
import org.apache.hc.client5.http.ssl.ClientTlsStrategyBuilder;
import org.apache.hc.client5.http.ssl.NoopHostnameVerifier;
import org.apache.hc.core5.http.HttpHost;
import org.apache.hc.core5.ssl.SSLContextBuilder;

public class LuceniaClientExample {

    public static void main(String[] args) throws Exception {
        var hosts = new HttpHost[]{new HttpHost("https", "localhost", 9200)};

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
                                new UsernamePasswordCredentials("admin", "MyStrongPassword123!".toCharArray()));
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

        String index = "sample-index";

        client.indices().create(CreateIndexRequest.of(i -> i.index(index)));

        client.indices().putSettings(
                PutIndicesSettingsRequest.of(p -> p.index(index)
                        .settings(IndexSettings.of(is -> is.autoExpandReplicas("0-all")))));

        client.index(IndexRequest.of(
                ir -> ir.index(index).id("1").document(new IndexData("first_name", "Bruce"))));

        client.search(s -> s.index(index), IndexData.class).hits().hits().forEach(hit -> {
            System.out.println(hit.source().toString());
        });

        client.delete(b -> b.index(index).id("1"));

        DeleteIndexResponse deleteIndexResponse = client.indices().delete(
                DeleteIndexRequest.of(i -> i.index(index)));

        if (!deleteIndexResponse.acknowledged()) {
            System.out.println("Index deletion failed");
        }
    }
}
