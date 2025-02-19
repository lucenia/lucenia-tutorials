package io.lucenia.tutorials;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;
import org.apache.http.HttpHost;
import org.apache.http.auth.AuthScope;
import org.apache.http.auth.UsernamePasswordCredentials;
import org.apache.http.client.CredentialsProvider;
import org.apache.http.impl.client.BasicCredentialsProvider;
import org.apache.http.impl.nio.client.HttpAsyncClientBuilder;
import org.opensearch.client.RestClient;
import org.opensearch.client.RestClientBuilder;
import org.opensearch.client.json.jackson.JacksonJsonpMapper;
import org.opensearch.client.opensearch.OpenSearchClient;
import org.opensearch.client.opensearch.core.IndexRequest;
import org.opensearch.client.opensearch.indices.CreateIndexRequest;
import org.opensearch.client.opensearch.indices.DeleteIndexRequest;
import org.opensearch.client.opensearch.indices.DeleteIndexResponse;
import org.opensearch.client.opensearch.indices.IndexSettings;
import org.opensearch.client.opensearch.indices.PutIndicesSettingsRequest;
import org.opensearch.client.transport.OpenSearchTransport;
import org.opensearch.client.transport.rest_client.RestClientTransport;

import java.io.IOException;

public class OpenSearchRestClientTransport {

    public static void main(String[] args) {
        RestClient restClient = null;
        String rootProgramDir = System.getProperty("user.dir");
        System.setProperty("javax.net.ssl.trustStore", rootProgramDir + "/src/main/resources/keystore.jks");
        // You can put the keystore in src/main/resources or use the following line with the path to the keystore
        // System.setProperty("javax.net.ssl.trustStore", "path/to/keystore.jks");
        System.setProperty("javax.net.ssl.trustStorePassword", "password");

        try{
            //Only for demo purposes. Don't specify your credentials in code.
            final CredentialsProvider credentialsProvider = new BasicCredentialsProvider();
            credentialsProvider.setCredentials(AuthScope.ANY,
                    new UsernamePasswordCredentials("admin", "myStrongPassword@123"));


            //Initialize the client with SSL and TLS enabled
            restClient = RestClient.builder(new HttpHost("localhost", 9200, "https")).
                    setHttpClientConfigCallback(new RestClientBuilder.HttpClientConfigCallback() {
                        @Override
                        public HttpAsyncClientBuilder customizeHttpClient(HttpAsyncClientBuilder httpClientBuilder) {
                            return httpClientBuilder.setDefaultCredentialsProvider(credentialsProvider)
                                    // Disable the SSL verification
                                    .setSSLHostnameVerifier((host, session) -> {
                                        return true;
                                    });
                        }
                    }).build();
            OpenSearchTransport transport = new RestClientTransport(restClient, new JacksonJsonpMapper());
            // Allow Insecure SSL
            OpenSearchClient client = new OpenSearchClient(transport);

            //Create the index
            String index = "sample-index";

            // Find if index exists
            client.indices().create(CreateIndexRequest.of(i -> i.index(index)));

            //Add some settings to the index
            client.indices().putSettings(
                    PutIndicesSettingsRequest.of(p -> p.index(index)
                            .settings(IndexSettings.of(is -> is.autoExpandReplicas("0-all")))));

            //Index some data
            client.index(IndexRequest.of(
                ir -> ir.index(index).id("1").document(new IndexData("first_name", "Bruce"))
            ));

            //Search for the document
            client.search(s -> s.index(index), IndexData.class).hits().hits().forEach(hit -> {
                hit.source().toString());
            });

            //Delete the document
            client.delete(b -> b.index(index).id("1"));

            // Delete the index
            DeleteIndexResponse deleteIndexResponse = client.indices().delete(
                    DeleteIndexRequest.of(i -> i.index(index))
            );

            if (!deleteIndexResponse.acknowledged()) {
                System.out.println("Index deletion failed");
            }
        } catch (IOException e){
            System.out.println(e.toString());
        } catch (Exception e) {
            System.out.println(e.toString());
        } finally {
            try {
                if (restClient != null) {
                    restClient.close();
                }
            } catch (IOException e) {
                System.out.println(e.toString());
            }
        }
    }
}