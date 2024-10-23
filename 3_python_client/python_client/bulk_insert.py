from opensearchpy import OpenSearch
from opensearchpy.helpers import bulk
import json

# OpenSearch client configuration
client = OpenSearch(
    hosts=[{"host": "localhost", "port": 9200}],
    http_compress=True,
    http_auth=("admin", "MyStrongPassword123!"),
    use_ssl=False,
    verify_certs=False,
    ssl_assert_hostname=False,
    ssl_show_warn=False,
)

if not client.indices.exists(index="flood_plane"):
    flood_plane_mappings = {
        "mappings": {
            "properties": {
                "flood_zone_coordinates": {"type": "geo_shape"},
                "flood_zone_rating": {"type": "keyword"},
            }
        }
    }
    client.indices.create("flood_plane", body=flood_plane_mappings)

if not client.indices.exists(index="buildings"):
    building_mappings = {
        "mappings": {"properties": {"building": {"type": "geo_shape"}}}
    }
    client.indices.create("buildings", body=building_mappings)

bulk_buildings = []
with open("./sample_data/NorthCarolinaBuildings_Bulk_filtered.json", "r") as f:
    for i, line in enumerate(f):
        line = json.loads(line)

        data = {
            "_index": "buildings",
            "_id": i,
            "_source": {
                "building": line["building"],
            },
        }
        bulk_buildings.append(data)
bulk(client, bulk_buildings, raise_on_error=False)

bulk_flood_planes = []
if client.count(index="flood_plane")["count"] == 0:
    with open("./sample_data/flood_zone_bulk.json", "r") as f:
        for i, line in enumerate(f):
            line = json.loads(line)
            # update the sample data

            if i % 2 == 1:

                data = {
                    "_index": "flood_plane",
                    "_id": i,
                    "_source": {
                        "flood_zone_coordinates": line["flood_zone_coordinates"],
                        "flood_zone_rating": line["flood_zone_rating"],
                    },
                }

                bulk_flood_planes.append(data)
bulk(client, bulk_flood_planes, raise_on_error=False)
