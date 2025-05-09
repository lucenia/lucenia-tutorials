import json
from shapely.geometry import Polygon, shape

asheville_coords = [
    (-82.70735648123342, 35.4685322658313),
    (-82.34339079754214, 35.4685322658313),
    (-82.34339079754214, 35.664035294486254),
    (-82.70735648123342, 35.664035294486254),
    (-82.70735648123342, 35.4685322658313),
]

bounding_box = Polygon(asheville_coords)


def convert_geojson_to_bulk_json(geojson_file, bulk_json_file, index_name):
    with open(geojson_file, "r") as f:
        geojson_data = json.load(f)

    bulk_data = []

    for feature in geojson_data["features"]:
        coordinates = feature["geometry"]["coordinates"]

        # Create the document
        document = {
            "building": {
                "type": "polygon",
                "coordinates": coordinates,
            }
        }

        building_coords_poly = shape({"type": "Polygon", "coordinates": coordinates})
        if bounding_box.contains(building_coords_poly):
            bulk_data.append(document)

    # Write the bulk data to the output file
    with open(bulk_json_file, "w") as f:
        for entry in bulk_data:
            f.write(json.dumps(entry) + "\n")


if __name__ == "__main__":
    geojson_file = "./NorthCarolina.geojson"
    bulk_json_file = "NorthCarolinaBuildings_Bulk_filtered.json"
    index_name = "buildings"

    convert_geojson_to_bulk_json(geojson_file, bulk_json_file, index_name)
