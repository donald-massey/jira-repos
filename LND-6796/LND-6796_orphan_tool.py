"""LND-6796: Cross-database tooling for Shape 1 xref orphans.

Two subcommands:

  check   Reads orphaned RecordIDs from LND-6796_shape1_orphans.csv — RecordIDs
          in CS_Digital.dbo.tblDimlXref under multi-record package_ids that are
          absent from CS_Digital.dbo.tblRecord — and checks whether any exist in
          tblRecord across all three databases (CS_Digital, countyScansTitle,
          courthousedirecttitle). A RecordID absent from all three is a true
          orphan whose xref row was left behind after a hard delete and can be
          removed. Writes LND-6796_shape1_orphan_xdb_results.csv.

  export  Reads LND-6796_shape1_orphan_xdb_results.csv and exports full record
          detail for the 154 non-orphans (those that DID turn up in a sibling DB)
          to one CSV per database. countyScansTitle Query 1 and
          courthousedirecttitle Query 2 in LND-6796_primary_issue_orphan_cleanup.sql
          run on separate servers and can't be exported together from one SSMS
          window; this does both:
              LND-6796_orphans_countyScansTitle.csv       (153 records)
              LND-6796_orphans_courthousedirecttitle.csv  (1 record)

Uses Windows auth when no USERNAME/PASSWORD env vars are set for a database,
SQL Server auth otherwise.

Usage (PowerShell, from the repo root where .venv lives):
  .\.venv\Scripts\pip install -r requirements.txt
  .\.venv\Scripts\python.exe LND-6796_orphan_tool.py check
  .\.venv\Scripts\python.exe LND-6796_orphan_tool.py export

Input/output CSVs live in the csv/ folder next to this script and are resolved
there regardless of the current working directory.

Env vars (copy .env.example -> .env and fill in):
  CSD_SERVER / CSD_DATABASE               CS_Digital (Windows auth)
  CST_SERVER / CST_DATABASE               countyScansTitle (Windows auth)
  CHD_SERVER / CHD_DATABASE               courthousedirecttitle
  CHD_USERNAME / CHD_PASSWORD             SQL Server auth for CHD (omit for Windows auth)

VPN must be up.

CASING / SCHEMA CAVEAT: export assumes countyScansTitle and courthousedirecttitle
share CS_Digital's tblRecord / tblLookupCounties / tblLookupStates schema and
column casing. Verify against each DB before running; adjust DETAIL_QUERY if a
sibling DB differs.
"""
import csv
import os
import sys
from datetime import datetime, timezone

import pyodbc
from dotenv import load_dotenv


# Anchor all CSV paths to the csv/ folder next to this script so the tool runs
# from any cwd (e.g. invoked from another directory), not just from the repo root.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_DIR = os.path.join(SCRIPT_DIR, "csv")

ORPHANS_FILE = "LND-6796_shape1_orphans.csv"
RESULTS_FILE = "LND-6796_shape1_orphan_xdb_results.csv"


def csv_path(name):
    """Resolve a CSV filename against the csv/ folder next to this script."""
    return os.path.join(CSV_DIR, name)

# Databases the `check` subcommand looks up each RecordID in.
DB_CONFIGS = [
    {"key": "CSD", "label": "CS_Digital",            "db_default": "CS_Digital"},
    {"key": "CST", "label": "countyScansTitle",      "db_default": "countyScansTitle"},
    {"key": "CHD", "label": "courthousedirecttitle", "db_default": "courthousedirecttitle"},
]

# One export per sibling DB the `export` subcommand writes.
EXPORTS = [
    {
        "key":        "CST",
        "db_default": "countyScansTitle",
        "verdict":    "found_in_countyScansTitle",
        "output":     "LND-6796_orphans_countyScansTitle.csv",
    },
    {
        "key":        "CHD",
        "db_default": "courthousedirecttitle",
        "verdict":    "found_in_courthousedirecttitle",
        "output":     "LND-6796_orphans_courthousedirecttitle.csv",
    },
]

DETAIL_QUERY = """
    SELECT
        r.recordID,
        r.CountyID,
        lc.CountyName,
        ls.StateAbbreviation,
        r.recordNumber,
        r.fileDate,
        r.statusID,
        r.originalFileName,
        r.storageFilePath
    FROM #ids i
    JOIN dbo.tblRecord r                ON r.recordID = i.RecordID
    LEFT JOIN dbo.tblLookupCounties lc  ON lc.CountyID = r.CountyID
    LEFT JOIN dbo.tblLookupStates   ls  ON ls.StateID  = lc.StateID
    ORDER BY r.CountyID, r.recordID
"""


def build_conn_string(server, database, username=None, password=None):
    base = (
        "DRIVER={ODBC Driver 17 for SQL Server};"
        f"SERVER={server};"
        f"DATABASE={database};"
    )
    if username:
        return base + f"UID={username};PWD={password};"
    return base + "Trusted_Connection=yes;"


def resolve_db(key, db_default):
    """Read SERVER/DATABASE/USERNAME/PASSWORD env vars for one DB key; exit if server missing."""
    server = os.environ.get(f"{key}_SERVER")
    if not server:
        sys.exit(f"Missing required env var: {key}_SERVER")
    database = os.environ.get(f"{key}_DATABASE", db_default)
    username = os.environ.get(f"{key}_USERNAME")
    password = os.environ.get(f"{key}_PASSWORD")
    auth = "SQL auth" if (username and password) else "Windows auth"
    return {
        "server":      server,
        "database":    database,
        "auth":        auth,
        "conn_string": build_conn_string(server, database, username, password),
    }


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
def lookup_in_tblrecord(conn_str, record_ids):
    """Return the set of RecordIDs that exist in dbo.tblRecord for this connection."""
    found = set()
    with pyodbc.connect(conn_str) as conn:
        cursor = conn.cursor()
        cursor.fast_executemany = True

        cursor.execute("CREATE TABLE #lookup_ids (RecordID VARCHAR(50))")

        print(f"  Batch Sent    : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}")
        cursor.executemany(
            "INSERT INTO #lookup_ids VALUES (?)",
            [(rid,) for rid in record_ids],
        )
        print(f"  Batch Received: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}")

        cursor.execute("""
            SELECT r.recordID
            FROM dbo.tblRecord r
            JOIN #lookup_ids l ON l.RecordID = r.recordID
        """)
        for row in cursor.fetchall():
            found.add(row[0])
    return found


def load_orphan_ids(path):
    """Read orphaned_RecordID column from the shape1 orphans CSV."""
    ids = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            rid = row.get("orphaned_RecordID", "").strip()
            if rid:
                ids.append(rid)
    return ids


def run_check():
    load_dotenv()

    print(f"Input : {ORPHANS_FILE}")
    record_ids = load_orphan_ids(csv_path(ORPHANS_FILE))
    print(f"Loaded: {len(record_ids):,} orphaned RecordIDs\n")

    results = {}  # label -> set of found RecordIDs
    for db in DB_CONFIGS:
        cfg = resolve_db(db["key"], db["db_default"])
        print(f"Querying {db['label']} on {cfg['server']} ({cfg['auth']}) ...")
        found = lookup_in_tblrecord(cfg["conn_string"], record_ids)
        results[db["label"]] = found
        print(f"  Found: {len(found):,}")

    labels = [db["label"] for db in DB_CONFIGS]
    true_orphan_count = sum(
        1 for r in record_ids if all(r not in results[l] for l in labels)
    )

    print(f"\nSummary")
    print(f"  Total orphaned RecordIDs : {len(record_ids):,}")
    for label in labels:
        print(f"  Found in {label:<30}: {len(results[label]):,}")
    print(f"  True orphans (not in any): {true_orphan_count:,}")

    out_cols = ["RecordID"] + [f"in_{l}" for l in labels] + ["verdict"]
    with open(csv_path(RESULTS_FILE), "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=out_cols)
        writer.writeheader()
        for rid in record_ids:
            found_in = [l for l in labels if rid in results[l]]
            verdict = "true_orphan" if not found_in else f"found_in_{'_and_'.join(found_in)}"
            row = {"RecordID": rid, "verdict": verdict}
            for label in labels:
                row[f"in_{label}"] = "YES" if rid in results[label] else "NO"
            writer.writerow(row)

    print(f"\nWrote: {RESULTS_FILE}")


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------
def load_record_ids_by_verdict(path, verdict):
    """Read RecordIDs from the xdb-results CSV whose verdict column matches."""
    ids = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            if row.get("verdict", "").strip() == verdict:
                rid = row.get("RecordID", "").strip()
                if rid:
                    ids.append(rid)
    return ids


def export_records(conn_str, record_ids, output_file):
    """Run DETAIL_QUERY against a temp table of record_ids and write the rows to CSV."""
    with pyodbc.connect(conn_str) as conn:
        cursor = conn.cursor()
        cursor.fast_executemany = True
        cursor.execute("CREATE TABLE #ids (RecordID VARCHAR(50) PRIMARY KEY)")
        cursor.executemany(
            "INSERT INTO #ids VALUES (?)",
            [(rid,) for rid in record_ids],
        )
        cursor.execute(DETAIL_QUERY)
        columns = [d[0] for d in cursor.description]
        rows = cursor.fetchall()

    with open(output_file, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(columns)
        writer.writerows(rows)
    return len(rows)


def run_export():
    load_dotenv()

    for exp in EXPORTS:
        cfg = resolve_db(exp["key"], exp["db_default"])

        record_ids = load_record_ids_by_verdict(csv_path(RESULTS_FILE), exp["verdict"])
        print(f"{cfg['database']} on {cfg['server']} ({cfg['auth']}): "
              f"{len(record_ids):,} RecordIDs to export")

        if not record_ids:
            print(f"  No RecordIDs matched verdict '{exp['verdict']}' — skipping.\n")
            continue

        written = export_records(cfg["conn_string"], record_ids, csv_path(exp["output"]))
        print(f"  Wrote {written:,} rows -> {exp['output']}\n")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else None
    if cmd == "check":
        run_check()
    elif cmd == "export":
        run_export()
    else:
        sys.exit("Usage: LND-6796_orphan_tool.py {check|export}")


if __name__ == "__main__":
    main()
