import csv
from opensearchpy import OpenSearch
from opensearchpy.helpers import bulk

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

# Create index for fire detections
if not client.indices.exists(index="fire_detections"):
    fire_mapping = {
        "mappings": {
            "properties": {
                "location": {"type": "geo_point"},
                "bright_ti4": {"type": "float"},
                "scan": {"type": "float"},
                "track": {"type": "float"},
                "acq_date": {"type": "date", "format": "yyyy-MM-dd"},
                "acq_time": {"type": "keyword"},
                "satellite": {"type": "keyword"},
                "confidence": {"type": "keyword"},
                "version": {"type": "keyword"},
                "bright_ti5": {"type": "float"},
                "frp": {"type": "float"},
                "daynight": {"type": "keyword"},
            }
        }
    }
    client.indices.create(index="fire_detections", body=fire_mapping)

# Read and bulk index CSV data
bulk_fire_data = []
with open("./sample_data/SUOMI_VIIRS_C2_USA_contiguous_and_Hawaii_7d.csv", newline="") as csvfile:
    reader = csv.DictReader(csvfile)
    for i, row in enumerate(reader):
        doc = {
            "_index": "fire_detections",
            "_id": i,
            "_source": {
                "location": {
                    "lat": float(row["latitude"]),
                    "lon": float(row["longitude"]),
                },
                "bright_ti4": float(row["bright_ti4"]),
                "scan": float(row["scan"]),
                "track": float(row["track"]),
                "acq_date": row["acq_date"],
                "acq_time": row["acq_time"],
                "satellite": row["satellite"],
                "confidence": row["confidence"],
                "version": row["version"],
                "bright_ti5": float(row["bright_ti5"]),
                "frp": float(row["frp"]),
                "daynight": row["daynight"],
            },
        }
        bulk_fire_data.append(doc)

bulk(client, bulk_fire_data, raise_on_error=False)