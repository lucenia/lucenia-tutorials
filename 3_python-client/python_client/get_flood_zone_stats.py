from opensearchpy import OpenSearch

# Define the OpenSearch endpoint and indices
OPENSEARCH_URL = "http://localhost:9200"
FLOOD_plain_INDEX = "flood_plain"
BUILDINGS_INDEX = "buildings"

# Initialize the OpenSearch client
client = OpenSearch(
    hosts=[{"host": "localhost", "port": 9200}],
    http_auth=("user", "password"),  # Replace with your credentials
    use_ssl=False,
    verify_certs=False,
)


def buildings_in_flood_zone_count(flood_zone_polygon):
    # Query to find buildings within the flood zone polygon
    buildings_query = {
        "query": {
            "bool": {
                "filter": {
                    "geo_shape": {
                        "building": {
                            "shape": {
                                "type": "polygon",
                                "coordinates": flood_zone_polygon,
                            },
                            "relation": "within",
                        }
                    }
                }
            }
        }
    }

    # Send request to count buildings
    buildings_response = client.search(
        index=BUILDINGS_INDEX,
        body=buildings_query,
        size=1000,
    )

    buildings = buildings_response["hits"]["total"]["value"]

    return buildings


def get_flood_zones():
    # Query to get all flood zones
    flood_zone_query = {"query": {"match_all": {}}}

    # Send request to get flood zones
    flood_zone_response = client.search(
        index=FLOOD_plain_INDEX, body=flood_zone_query, size=1100
    )

    print(f"Total flood zones: {flood_zone_response['hits']['total']['value']}")

    flood_zones = flood_zone_response["hits"]["hits"]

    return flood_zones


def flood_zone_categories_count():
    flood_zone_categories_count = {}

    flood_zones = get_flood_zones()

    for flood_zone in flood_zones:
        flood_zone_rating = flood_zone["_source"]["flood_zone_rating"]
        flood_zone_coords_list = flood_zone["_source"]["flood_zone_coordinates"][
            "coordinates"
        ]

        buildings_count = buildings_in_flood_zone_count(flood_zone_coords_list)

        flood_zone_categories_count.setdefault(flood_zone_rating, 0)
        flood_zone_categories_count[flood_zone_rating] += buildings_count

    return flood_zone_categories_count


if __name__ == "__main__":

    flood_zone_categories_count()
