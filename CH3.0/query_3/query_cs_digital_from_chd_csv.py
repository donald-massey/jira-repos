"""query_3: verify which courthouseDirectTitle (CHD) recordIDs exist in
CS_Digital's COLE processing pipeline (courthouse-direct-title.csv).

CHD recordIDs are NOT present in CS_Digital.tblrecord — they link
via tblDimlXref.recordID instead. So this drives off the CHD recordIDs into:
    tblDimlXref                    (package_id / s3key)
    cole.tblRecordProcessingLogs   (OCR / IIE timestamps + error msgs), on package_id
per the join used to confirm COLE presence. LEFT JOINs + in_diml_xref / in_cole_logs
flags so CHD records with no DIML xref or no COLE log show up as rows, not omissions.

The GUIDs are bulk-loaded into a #chd_ids temp table (one connection, fast_executemany)
and the join runs as a single scan — no chunked IN() lists.

CHD (courthouseDirectTitle) and CS_Digital live on DIFFERENT servers, so this reads
the recordIDs from the CSV and queries CS_Digital directly — no linked server.

Usage (PowerShell):
  .\\.venv\\Scripts\\python.exe query_cs_digital_from_chd_csv.py
  .\\.venv\\Scripts\\python.exe query_cs_digital_from_chd_csv.py --input courthouse-direct-title.csv --output cs_digital_match.csv --limit 500
"""
import argparse
import csv
import os
import sys
from pathlib import Path

import pyodbc

# CHD recordIDs link to CS_Digital via tblDimlXref.recordID (NOT tblrecord — CHD
# recordIDs don't exist there). From the xref, package_id ties to the COLE processing
# logs. LEFT JOINs + presence flags so CHD records absent from DIML/COLE surface as
# rows (in_diml_xref=0 / in_cole_logs=0) instead of being silently dropped.
DIAGNOSTIC_SQL = """
SELECT
    t.recordID AS chd_recordID,
    CASE WHEN d.recordID  IS NOT NULL THEN 1 ELSE 0 END AS in_diml_xref,
    CASE WHEN l.package_id IS NOT NULL THEN 1 ELSE 0 END AS in_cole_logs,
    d.*,
    l.*
FROM #chd_ids t
LEFT JOIN CS_Digital.dbo.tblDimlXref d ON d.recordID = t.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = d.package_id
ORDER BY l.package_id
"""


def read_record_ids(csv_path):
    """First column of the CHD export is recordID. Return the de-duped GUIDs in file order."""
    seen = set()
    ids = []
    # utf-8-sig strips the BOM SSMS writes, which would corrupt the first header/value.
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        next(reader, None)  # header row
        for row in reader:
            if not row:
                continue
            rid = row[0].strip()
            if rid and rid not in seen:
                seen.add(rid)
                ids.append(rid)
    return ids


def connect_csd():
    server = os.environ.get("CSD_SERVER", "aus2-ch2-petl01v.na.drillinginfo.com")
    database = os.environ.get("CSD_DATABASE") or os.environ.get("CSD_DB", "CS_Digital")
    conn_str = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={server};"
        f"DATABASE={database};"
        f"Trusted_Connection=yes;"
        f"TrustServerCertificate=yes;"
    )
    print(f"Connecting to {database} on {server} ...", file=sys.stderr)
    return pyodbc.connect(conn_str, autocommit=True)


def load_temp_ids(cursor, record_ids, batch_size=1000):
    """Create #chd_ids and bulk-insert the recordIDs on this connection."""
    cursor.execute("CREATE TABLE #chd_ids (recordID uniqueidentifier PRIMARY KEY)")
    cursor.fast_executemany = True
    for i in range(0, len(record_ids), batch_size):
        chunk = record_ids[i : i + batch_size]
        cursor.executemany(
            "INSERT INTO #chd_ids (recordID) VALUES (?)", [(rid,) for rid in chunk]
        )
        print(f"  loaded {min(i + batch_size, len(record_ids))}/{len(record_ids)} ids", file=sys.stderr)


def dedupe_headers(columns):
    """SELECT * across the joined tables repeats column names (recordID, _ModifiedDateTime,
    countyID, ...). Suffix duplicates so the CSV header is unique and nothing is dropped."""
    counts = {}
    out = []
    for col in columns:
        name = col or "col"
        if name in counts:
            counts[name] += 1
            out.append(f"{name}_{counts[name]}")
        else:
            counts[name] = 0
            out.append(name)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="courthouse-direct-title.csv",
                        help="CHD export CSV (recordID in first column)")
    parser.add_argument("--output", default="cs_digital_cole_check.csv", help="output CSV path")
    parser.add_argument("--limit", type=int, default=0,
                        help="only load the first N recordIDs (0 = all)")
    args = parser.parse_args()

    here = Path(__file__).parent
    input_path = args.input if os.path.isabs(args.input) else here / args.input
    output_path = args.output if os.path.isabs(args.output) else here / args.output

    record_ids = read_record_ids(input_path)
    if args.limit:
        record_ids = record_ids[: args.limit]
    print(f"{len(record_ids)} distinct recordIDs from {input_path}", file=sys.stderr)
    if not record_ids:
        sys.exit("No recordIDs found in input CSV.")

    conn = connect_csd()
    try:
        cursor = conn.cursor()
        load_temp_ids(cursor, record_ids)

        cursor.execute(DIAGNOSTIC_SQL)
        headers = dedupe_headers([col[0] for col in cursor.description])

        written = 0
        with open(output_path, "w", newline="", encoding="utf-8") as out:
            writer = csv.writer(out)
            writer.writerow(headers)
            while True:
                rows = cursor.fetchmany(5000)
                if not rows:
                    break
                writer.writerows(rows)
                written += len(rows)
                print(f"  wrote {written} rows", file=sys.stderr)
    finally:
        conn.close()

    print(f"Done. {len(record_ids)} CHD recordIDs queried -> {written} CS_Digital rows -> {output_path}")


if __name__ == "__main__":
    try:
        from dotenv import load_dotenv

        env_file = Path(__file__).parent.parent / ".env"
        if env_file.exists():
            load_dotenv(env_file)
            print(f"Loaded env from {env_file}", file=sys.stderr)
    except ImportError:
        pass
    main()
