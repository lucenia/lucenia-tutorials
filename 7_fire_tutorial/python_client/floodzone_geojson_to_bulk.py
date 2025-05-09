import json
import uuid


def convert_geojson_to_bulk_json(geojson_file, bulk_json_file, index_name):
    with open(geojson_file, "r") as f:
        geojson_data = json.load(f)

    bulk_data = []

    for feature in geojson_data["features"]:
        # Generate a unique ID for each feature
        feature_id = str(uuid.uuid4())

        # Create the index metadata
        index_metadata = {"index": {"_index": index_name, "_id": feature_id}}

        # Extract the coordinates and FLD_ZONE
        coordinates = feature["geometry"]["coordinates"]
        fld_zone = feature["properties"].get("ZONE_LID_VALUE", "Unknown")

        # Create the document
        document = {
            "flood_zone_coordinates": {"type": "polygon", "coordinates": coordinates},
            "flood_zone_rating": fld_zone,
        }

        # Append the index metadata and document to the bulk data
        bulk_data.append(index_metadata)
        bulk_data.append(document)

    # Write the bulk data to the output file
    with open(bulk_json_file, "w") as f:
        for entry in bulk_data:
            f.write(json.dumps(entry) + "\n")


if __name__ == "__main__":
    geojson_file = "./North_Carolina_Flood_Hazard_Area_Effective.geojson"
    bulk_json_file = "flood_zone_bulk.json"
    index_name = "flood_plain"

    convert_geojson_to_bulk_json(geojson_file, bulk_json_file, index_name)
