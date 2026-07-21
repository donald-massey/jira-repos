# LND-8093 — Backfill CSTitle S3Images

Copies all records in `countyScansTitle.dbo.tblrecord` that don't yet have an entry in `tblS3Image` to S3, then inserts the results into `tblS3Image`. Runs in two phases — a parallel uploader (`main.py`) that streams per-batch result CSVs, and a finalize step (`finalize_from_csv.py`) that loads the successes into `tblS3Image`.

## Prerequisites

- Python 3.9+
- ODBC Driver 17 for SQL Server
- Network access to the countyScansTitle file share (`storageFilePath` values in `tblrecord`)
- Valid AWS credentials (short-lived — refresh before running)

## Setup

```
pip install -r requirements.txt
```

Copy `.env.example` to `.env` and fill in both the AWS credentials and the countyScansTitle credentials:

```
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
AWS_SESSION_TOKEN=<token>

cstitle_server=<server>
cstitle_username=<user>
cstitle_password=<pass>
```

`load_dotenv()` loads these into the environment at startup, so boto3 picks up the `AWS_*` values automatically.

Refresh the AWS keys in `.env` immediately before running — they are short-lived and a stale token will fail the job mid-run.

## Scope

Scan run 2026-06-29 (`scan_affected_records.sql`):

| Scope | Records |
| --- | --- |
| No exclusions (the backfill) | **9,050,952** |
| With LND-6827 filters | 890 |

The job is **~9.05M files**, heavily concentrated: TX (68%) + NM (20%) = 88%, top 5 states (TX, NM, LA, ND, OK) = 96%. Full breakdown in `LND-8093_Breakdown By State.csv`.

## Before Running

**Filter decision (resolved):** the LND-6827 filters (`recordIsLease=1`, `statusID IN (4,16)`, `fileDate>='2002-01-01'`) are **intentionally left off** — applying them collapses the job to 890 records and defeats the ticket. They stay commented out in `main.py`. The **county exclusion list** (IDs 288–300, 684–716, 1187) is **also left off**: it was traced to LND-6827's lease-scoped source query (an out-of-lease-scope / EOG-keying artifact, not a bad-data flag), so it has no place in a broad sweep. The `countyID NOT IN (...)` block stays commented out.

**Run state-by-state.** Don't run all 9M in one pass — the parent holds the work list in memory, so scope each run with `STATE` (TX and NM each on their own) and window very large states with `ROW_LIMIT`. `main.py` refuses `STATE=ALL` with no `ROW_LIMIT` unless you set `ALLOW_FULL_SCAN=true`, and warns whenever a run loads more than `WARN_WORK_THRESHOLD` (default 1M) records. Runs are resumable: records already in `tblS3Image` and records already finished in prior CSVs are skipped automatically, so a stale token or crash only costs the in-flight batch. Validate end-to-end on a small state first (e.g. `STATE=SD`, 830 records) before launching TX. Refresh AWS keys immediately before each run.

## Run

Two phases. Set scope via `.env` or shell env (`STATE`, `ROW_LIMIT`, `MAX_WORKERS`, `VERIFY_UPLOADS`):

```
python main.py              # phase 1: upload files to S3, stream per-batch result CSVs
python finalize_from_csv.py # phase 2: insert copied rows into tblS3Image, archive CSVs
```

**Phase 1 (`main.py`)** builds the per-state work snapshot (`LND_8093_STAGE_{STATE}`), fans records across `MAX_WORKERS` Pebble workers, and each worker reads file size + PDF page count, uploads to S3, and streams outcomes to `migration_results/s3_backfill_batch_{STATE}_{N}_{timestamp}_{pid}.csv` with `status` of `copied` / `file_not_found` / `error`. The timestamp+PID suffix keeps re-run CSVs from overwriting each other.

**Phase 2 (`finalize_from_csv.py`)** reads those CSVs and idempotently inserts every `status='copied'` row into `tblS3Image`, then moves each CSV to `migration_results/processed_archive/`.

Inspect the CSVs between phases — finalize only writes `copied` rows, so phase 1 output is safe to review before anything touches `tblS3Image`.

**Windowing a large state — finalize between every window.** `load_work()` selects `TOP {ROW_LIMIT}` rows not yet in `tblS3Image` (no `ORDER BY`, so *which* rows is arbitrary), and only `finalize_from_csv.py` puts rows there. If you run `main.py` twice without finalizing in between, the second run re-selects from the **same pending pool** (nothing moved to `tblS3Image`), the CSV resume filter skips the rows the first run already handled, and you mostly re-tread ground — little real progress, and the run can report "Nothing to process. Done." while millions remain. For TX (~6.2M) the loop is strictly `main.py` → `finalize_from_csv.py` → repeat until `load_work` returns 0. Single-pass states (no `ROW_LIMIT`) aren't affected.

## Verifying Results

```sql
-- Count inserted per county, most recently modified first
SELECT
    tlc.countyName,
    tls.stateAbbreviation,
    COUNT(*) AS inserted,
    MAX(s._ModifiedDateTime) AS last_modified
FROM countyScansTitle.dbo.tblS3Image s
JOIN countyScansTitle.dbo.tblrecord tr ON tr.recordID = s.recordID
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.countyID = tr.countyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.stateID = tr.stateID
WHERE s._ModifiedBy = 'LND-8093'
GROUP BY tlc.countyName, tls.stateAbbreviation
ORDER BY last_modified DESC;
```

```
# Failures and missing files (from the result CSVs)
migration_results/s3_backfill_batch_*.csv          -> rows with status = error
migration_results/processed_archive/*.csv          -> archived after finalize
```

Grep the CSVs for `,error,` (S3/upload failures to retry) and `,file_not_found,` (paths not on disk to hand off).

## S3 Path Format

```
s3://enverus-courthouse-prod-chd-plants/{state}/{county}/{recordID[0:4]}/{recordID}{ext}
```

Example: `s3://enverus-courthouse-prod-chd-plants/tx/harris/0001/0001abc123.pdf`