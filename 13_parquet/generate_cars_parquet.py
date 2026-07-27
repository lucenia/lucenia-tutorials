#!/usr/bin/env python3
"""Generate the sample Parquet file used by the index-free search tutorial.

The dataset is the classic 32-row ``mtcars`` table (so the mount response
matches the numbers in the Lucenia docs) enriched with a few extra columns that
deliberately exercise every branch of Lucenia's Parquet schema inference:

  model          string        -> keyword   (used as the document _id)
  mpg            double        -> double
  cyl            int32         -> integer
  hp             int32         -> integer
  wt             double        -> double
  gear           int32         -> integer
  am             bool          -> boolean    (preserved in _source, not
                                              directly queryable until reindex)
  last_serviced  timestamp[ms] -> long       (epoch milliseconds, NOT a date)
  raw_signature  binary        -> skipped    (non-string binary is not mapped)

Only the UNCOMPRESSED and SNAPPY Parquet codecs are supported by the reader, so
the file is written with SNAPPY compression.
"""

import sys
from datetime import datetime, timedelta, timezone

import pyarrow as pa
import pyarrow.parquet as pq

# --- The canonical mtcars dataset (32 rows) --------------------------------
MODEL = [
    "Mazda RX4", "Mazda RX4 Wag", "Datsun 710", "Hornet 4 Drive",
    "Hornet Sportabout", "Valiant", "Duster 360", "Merc 240D", "Merc 230",
    "Merc 280", "Merc 280C", "Merc 450SE", "Merc 450SL", "Merc 450SLC",
    "Cadillac Fleetwood", "Lincoln Continental", "Chrysler Imperial",
    "Fiat 128", "Honda Civic", "Toyota Corolla", "Toyota Corona",
    "Dodge Challenger", "AMC Javelin", "Camaro Z28", "Pontiac Firebird",
    "Fiat X1-9", "Porsche 914-2", "Lotus Europa", "Ford Pantera L",
    "Ferrari Dino", "Maserati Bora", "Volvo 142E",
]
MPG = [21.0, 21.0, 22.8, 21.4, 18.7, 18.1, 14.3, 24.4, 22.8, 19.2, 17.8,
       16.4, 17.3, 15.2, 10.4, 10.4, 14.7, 32.4, 30.4, 33.9, 21.5, 15.5,
       15.2, 13.3, 19.2, 27.3, 26.0, 30.4, 15.8, 19.7, 15.0, 21.4]
CYL = [6, 6, 4, 6, 8, 6, 8, 4, 4, 6, 6, 8, 8, 8, 8, 8, 8, 4, 4, 4, 4, 8, 8,
       8, 8, 4, 4, 4, 8, 6, 8, 4]
HP = [110, 110, 93, 110, 175, 105, 245, 62, 95, 123, 123, 180, 180, 180, 205,
      215, 230, 66, 52, 65, 97, 150, 150, 245, 175, 66, 91, 113, 264, 175,
      335, 109]
WT = [2.620, 2.875, 2.320, 3.215, 3.440, 3.460, 3.570, 3.190, 3.150, 3.440,
      3.440, 4.070, 3.730, 3.780, 5.250, 5.424, 5.345, 2.200, 1.615, 1.835,
      2.465, 3.520, 3.435, 3.840, 3.845, 1.935, 2.140, 1.513, 3.170, 2.770,
      3.570, 2.780]
GEAR = [4, 4, 4, 3, 3, 3, 3, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 4, 4, 4, 3, 3, 3,
        3, 3, 4, 5, 5, 5, 5, 5, 4]
# 1 = manual, 0 = automatic -> cast to a real boolean column
AM = [bool(x) for x in
      [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0,
       0, 0, 1, 1, 1, 1, 1, 1, 1]]

# --- Synthetic enrichment columns ------------------------------------------
# Deterministic service dates so the file is byte-reproducible across runs.
BASE = datetime(2026, 1, 5, 9, 0, 0, tzinfo=timezone.utc)
LAST_SERVICED = [BASE + timedelta(days=i * 9) for i in range(len(MODEL))]
# A non-UTF-8 binary column: the reader maps only string binary to keyword, so
# this column will appear under "skipped_columns" at mount time.
RAW_SIGNATURE = [bytes([0xC0, 0xFF, 0xEE, i & 0xFF]) for i in range(len(MODEL))]

schema = pa.schema([
    ("model", pa.string()),
    ("mpg", pa.float64()),
    ("cyl", pa.int32()),
    ("hp", pa.int32()),
    ("wt", pa.float64()),
    ("gear", pa.int32()),
    ("am", pa.bool_()),
    ("last_serviced", pa.timestamp("ms", tz="UTC")),
    ("raw_signature", pa.binary()),
])

table = pa.table(
    {
        "model": MODEL,
        "mpg": MPG,
        "cyl": CYL,
        "hp": HP,
        "wt": WT,
        "gear": GEAR,
        "am": AM,
        "last_serviced": LAST_SERVICED,
        "raw_signature": RAW_SIGNATURE,
    },
    schema=schema,
)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "node/config/data/cars.parquet"
    # SNAPPY is one of the two codecs the Parquet reader accepts.
    pq.write_table(table, out, compression="snappy")
    print(f"Wrote {table.num_rows} rows x {table.num_columns} columns -> {out}")
    print("\nParquet schema:")
    print(pq.read_schema(out))


if __name__ == "__main__":
    main()
