package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/lucenia/lucenia-go"
	"github.com/lucenia/lucenia-go/luceniaapi"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}
}

func run() error {
	host := getEnv("LUCENIA_HOST", "localhost")
	port := getEnv("LUCENIA_PORT", "9200")
	user := getEnv("LUCENIA_USER", "admin")
	password := getEnv("LUCENIA_PASSWORD", "MyStrongPassword123!")

	// -- 1. Create the client --
	fmt.Println("=== Creating Lucenia client ===")

	client, err := luceniaapi.NewClient(
		luceniaapi.Config{
			Client: lucenia.Config{
				Addresses:          []string{fmt.Sprintf("https://%s:%s", host, port)},
				Username:           user,
				Password:           password,
				InsecureSkipVerify: true, // For testing only. Use certificates in production.
			},
		},
	)
	if err != nil {
		return fmt.Errorf("creating client: %w", err)
	}

	ctx := context.Background()

	infoResp, err := client.Info(ctx, nil)
	if err != nil {
		return fmt.Errorf("getting info: %w", err)
	}
	fmt.Printf("Connected to %s %s\n", infoResp.Version.Distribution, infoResp.Version.Number)

	// -- 2. Create an index --
	indexName := "go-tutorial-index"

	_, err = client.Indices.Exists(ctx, luceniaapi.IndicesExistsReq{Indices: []string{indexName}})
	if err == nil {
		fmt.Printf("Index '%s' already exists, deleting it first...\n", indexName)
		_, err = client.Indices.Delete(ctx, luceniaapi.IndicesDeleteReq{Indices: []string{indexName}})
		if err != nil {
			return fmt.Errorf("deleting existing index: %w", err)
		}
	}

	fmt.Printf("\n=== Creating index: %s ===\n", indexName)
	createResp, err := client.Indices.Create(
		ctx,
		luceniaapi.IndicesCreateReq{
			Index: indexName,
			Body: strings.NewReader(`{
				"settings": {
					"index": {
						"number_of_shards": 1,
						"number_of_replicas": 0
					}
				},
				"mappings": {
					"properties": {
						"title": { "type": "text" },
						"text":  { "type": "text" },
						"year":  { "type": "integer" }
					}
				}
			}`),
		},
	)
	if err != nil {
		return fmt.Errorf("creating index: %w", err)
	}
	fmt.Printf("Index created: %t\n", createResp.Acknowledged)

	// -- 3. Index a single document --
	fmt.Println("\n=== Indexing a single document ===")
	indexResp, err := client.Index(
		ctx,
		luceniaapi.IndexReq{
			Index:      indexName,
			DocumentID: "1",
			Body:       strings.NewReader(`{"title": "Introduction to Lucenia", "text": "Lucenia is a high-performance search engine.", "year": 2025}`),
			Params:     luceniaapi.IndexParams{Refresh: "true"},
		},
	)
	if err != nil {
		return fmt.Errorf("indexing document: %w", err)
	}
	fmt.Printf("Indexed document 1: %s\n", indexResp.Result)

	// -- 4. Bulk index documents --
	fmt.Println("\n=== Bulk indexing documents ===")
	bulkBody := `{ "index": { "_index": "` + indexName + `", "_id": "2" } }
{ "title": "Getting Started with Go", "text": "Use the lucenia-go client to connect.", "year": 2025 }
{ "index": { "_index": "` + indexName + `", "_id": "3" } }
{ "title": "Search Features", "text": "Full-text search, aggregations, and more.", "year": 2025 }
{ "index": { "_index": "` + indexName + `", "_id": "4" } }
{ "title": "Bulk Operations", "text": "Efficiently index many documents at once.", "year": 2025 }
`
	bulkResp, err := client.Bulk(ctx, luceniaapi.BulkReq{
		Body:   strings.NewReader(bulkBody),
		Params: luceniaapi.BulkParams{Refresh: "wait_for"},
	})
	if err != nil {
		return fmt.Errorf("bulk indexing: %w", err)
	}
	fmt.Printf("Bulk indexed %d documents (errors: %t)\n", len(bulkResp.Items), bulkResp.Errors)

	// -- 5. Search all documents --
	fmt.Println("\n=== Search: match all ===")
	searchResp, err := client.Search(
		ctx,
		&luceniaapi.SearchReq{
			Indices: []string{indexName},
			Body:    strings.NewReader(`{ "query": { "match_all": {} } }`),
		},
	)
	if err != nil {
		return fmt.Errorf("searching: %w", err)
	}
	fmt.Printf("Found %d documents:\n", searchResp.Hits.Total.Value)
	for _, hit := range searchResp.Hits.Hits {
		var doc map[string]any
		json.Unmarshal(hit.Source, &doc)
		fmt.Printf("  [%s] %s\n", hit.ID, doc["title"])
	}

	// -- 6. Search with a match query --
	fmt.Println("\n=== Search: match query for 'Lucenia' ===")
	searchResp, err = client.Search(
		ctx,
		&luceniaapi.SearchReq{
			Indices: []string{indexName},
			Body:    strings.NewReader(`{ "query": { "match": { "title": "Lucenia" } } }`),
		},
	)
	if err != nil {
		return fmt.Errorf("searching: %w", err)
	}
	fmt.Printf("Found %d documents:\n", searchResp.Hits.Total.Value)
	for _, hit := range searchResp.Hits.Hits {
		var doc map[string]any
		json.Unmarshal(hit.Source, &doc)
		fmt.Printf("  [%s] score=%.4f %s\n", hit.ID, hit.Score, doc["title"])
	}

	// -- 7. Search with a multi_match query --
	fmt.Println("\n=== Search: multi_match for 'search' across title and text ===")
	searchResp, err = client.Search(
		ctx,
		&luceniaapi.SearchReq{
			Indices: []string{indexName},
			Body: strings.NewReader(`{
				"query": {
					"multi_match": {
						"query": "search",
						"fields": ["title^2", "text"]
					}
				}
			}`),
		},
	)
	if err != nil {
		return fmt.Errorf("searching: %w", err)
	}
	fmt.Printf("Found %d documents:\n", searchResp.Hits.Total.Value)
	for _, hit := range searchResp.Hits.Hits {
		var doc map[string]any
		json.Unmarshal(hit.Source, &doc)
		fmt.Printf("  [%s] score=%.4f %s\n", hit.ID, hit.Score, doc["title"])
	}

	// -- 8. Delete a document --
	fmt.Println("\n=== Deleting document id=1 ===")
	docDelResp, err := client.Document.Delete(ctx, luceniaapi.DocumentDeleteReq{
		Index:      indexName,
		DocumentID: "1",
	})
	if err != nil {
		return fmt.Errorf("deleting document: %w", err)
	}
	fmt.Printf("Document deleted: %s\n", docDelResp.Result)

	// -- 9. Delete the index --
	fmt.Printf("\n=== Deleting index: %s ===\n", indexName)
	delResp, err := client.Indices.Delete(ctx, luceniaapi.IndicesDeleteReq{
		Indices: []string{indexName},
	})
	if err != nil {
		return fmt.Errorf("deleting index: %w", err)
	}
	fmt.Printf("Index deleted: %t\n", delResp.Acknowledged)

	fmt.Println("\nDone!")
	return nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
