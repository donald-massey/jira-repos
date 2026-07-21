# LND-8093 — Backfill CSTitle S3Images For Remaining Available Images

## Goal

Backfill all records in `countyScansTitle.dbo.tblrecord` that don't yet have an entry in `countyScansTitle.dbo.tblS3Image`. For each record, copy the physical file from its network share path to S3 and insert a row into `tblS3Image` with the S3 path, page count, and file size.

This is the broad sweep following LND-6827, which only covered records tied to active DS9 leases. LND-8093 covers the rest.

## Stack

Python, boto3, PyPDF2, Pebble (multiprocessing), pyodbc (`ODBC Driver 17 for SQL Server`), python-dotenv.

Multiprocessing harness ported from `LND-7726` branch `vm_mod_claude-improvements` (chunk-per-worker `ProcessPool`, per-batch CSV results, CSV-based resume, `ExpiredToken` graceful stop, two-phase CSV→DB). Original upload/staging logic referenced from `LND-6827`.

## Database

**countyScansTitle** — SQL Server, credentials from `.env`:

```
cstitle_server=
cstitle_username=
cstitle_password=
```

Connection via `connect_countyscanstitle()` in `utils/database_utils.py` (reads the `cstitle_*` env vars).

## S3

**Bucket:** `enverus-courthouse-prod-chd-plants` (us-east-1)

**Key format:**
```
{stateAbbrev_lower}/{countyName_lower_no_dots}/{recordID[0:4].lower()}/{recordID.lower()}{fileExtension}
```

**s3FilePath stored as:**
```
s3://enverus-courthouse-prod-chd-plants/{state}/{county}/{first4}/{recordID}{ext}
```

## Source Query

Records in `countyScansTitle` not yet uploaded:

```sql
SELECT
    tr.recordID,
    LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '') AS state_countyname,
    tr.storageFilePath,
    tr.fileExtension,
    LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '') + '/' 
        + LEFT(tr.recordID, 4) + '/' + tr.recordID + tr.fileExtension AS s3_key
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.countyID = tr.countyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.stateID = tr.stateID
WHERE tr.storageFilePath != 'NONE'
  AND NOT EXISTS (SELECT 1 FROM countyScansTitle.dbo.tblS3Image s WHERE s.recordID = tr.recordID)
```

## Scan Results (2026-06-29)

Ran `scan_affected_records.sql` against countyScansTitle:

| Scope | Records |
| --- | --- |
| No exclusions (broad sweep) | **9,050,952** |
| With LND-6827 filters applied | **890** |

The full backfill population is **~9.05M records**. Applying the LND-6827 filters collapses it to 890 — LND-6827 already uploaded almost everything matching those filters (it was scoped to active DS9 leases), so reusing them here would gut the ticket.

**Volume is concentrated.** Top states (`LND-8093_Breakdown By State.csv`):

| State | Records | % |
| --- | --- | --- |
| TX | 6,193,471 | 68.4% |
| NM | 1,780,270 | 19.7% |
| LA | 282,810 | 3.1% |
| ND | 233,910 | 2.6% |
| OK | 233,276 | 2.6% |

TX + NM = 88% of the job; top 5 = 96%. The per-state breakdown sums to 9,050,947 — 5 short of the headline, so ~5 records have a `stateID` not present in `tbllookupStates`. The inner joins in `build_staging_table` silently drop those (and any record whose `countyID` has no match in `tbllookupCounties`); negligible at this scale but worth knowing the staged count won't exactly equal 9,050,952.

## Decision (resolved)

- **Do NOT apply** `recordIsLease`, `statusID`, or `fileDate` filters — they contradict the "backfill all remaining" goal. The filters in `main.py` stay commented out.
- **County exclusion list (IDs 288–300, 684–716, 1187) — RESOLVED: leave OFF.** Traced to LND-6827's lease-scoped source query (`main.py:357-358` and `LND-6827_Sql file UPDATE ME.sql:50-51`). There the `countyID NOT IN (...)` block sits inside a DS9 lease extraction (joins `tblexportLog` → `LND_6827_SRC_*`, gated by `recordIsLease=1`, `statusID IN (4,16)`, `fileDate >= '2002-01-01'`) with the inline note about EOG keying scope. It is an **out-of-lease-scope / EOG-keying artifact, not a bad-data or excluded-plant flag**. Confirmed with Tyler Jordan: those counties were excluded purely because of scope. Applying it to a broad sweep would wrongly drop legitimate records, so the `countyID NOT IN (...)` block in `build_staging_table` stays commented out.

## Scale / Execution Plan

9.05M files is far larger than LND-6827's scope. `main.py` as written runs the whole thing in one pass; at this scale that has two real problems:

1. **`gather_metadata` is single-threaded** — it iterates row-by-row over the network share opening every PDF. At 9M files this is the dominant bottleneck (days–weeks). Parallelize it (Pebble pool, same as the upload step) or fold metadata collection into the S3-upload worker so each file is touched once.
2. **No resumability** — one fatal error (stale AWS token, network blip) and the run restarts from zero. Loading 9M rows into a single DataFrame / `to_sql` is also memory-heavy.

**Implemented approach** (ported from LND-7726 `vm_mod_claude-improvements`): worker-parallel uploads with on-disk resumability. Metadata gathering is folded into the upload worker, and each worker streams its outcomes to a per-batch CSV. A PDF at or below `MAX_BUFFER_MB` (default 100, and not in verify mode) is read once into memory — page count and upload both come from that one buffer, so the file is touched once over the share; larger files and verify mode stream (separate page-count read + upload). Re-runs skip records already in `tblS3Image` (work query) and records already marked terminal in prior CSVs (resume filter), so a stale token or network blip costs only the in-flight rows. Scope a run to one state with `STATE=TX` and window a large state with `ROW_LIMIT=500000`. Validate a small state end-to-end (e.g. `STATE=SD`, 830 records) before launching TX. Refresh AWS keys immediately before each run.

## Local File Path

```python
local_path = os.path.join(row['storageFilePath'], row['recordID'] + row['fileExtension'])
```

Files must exist on disk before uploading. Skip and log records where the path doesn't exist.

## tblS3Image Schema

```sql
CREATE TABLE [dbo].[tblS3Image] (
    [recordID]          [varchar](36)  NOT NULL PRIMARY KEY,
    [s3FilePath]        [varchar](300) NOT NULL,
    [pageCount]         [int]          NULL,
    [fileSizeBytes]     [bigint]       NULL,
    [_ModifiedDateTime] [datetime]     NULL DEFAULT (getdate()),
    [_ModifiedBy]       [varchar](75)  NULL DEFAULT (suser_sname())
)
```

A per-state staging table (`LND_8093_STAGE_{STATE}`, e.g. `LND_8093_STAGE_TX`, or `LND_8093_STAGE_ALL`) holds the frozen work snapshot, built once via `SELECT INTO`. The finalize step inserts into `tblS3Image`.

## Architecture (two phases)

**Code layout:**
- `utils/database_utils.py` — `DatabaseConnection` (pyodbc; deadlock-retrying `execute_many`/`execute_update`; transactions) + `connect_countyscanstitle()`.
- `utils/s3_utils.py` — `S3Client` (boto3 wrapper, `max_attempts=10`/`mode='standard'`, `upload_file`/`upload_and_verify`).
- `utils/process_utils.py` — `process_batch()` worker.
- `main.py` — phase 1 (parallel upload).
- `finalize_from_csv.py` — phase 2 (CSV → `tblS3Image`).

**Phase 1 — `python main.py`:**
1. `build_staging_table()` — `SELECT INTO LND_8093_STAGE_{STATE}` if it doesn't already exist (frozen work snapshot; honors `STATE` filter).
2. `load_work()` — reads pending rows from staging, excluding any already in `tblS3Image` via `NOT EXISTS` (self-prunes across finalize runs). Optional `ROW_LIMIT` windows the run.
3. `load_already_processed_ids()` — scans only **this state's** CSVs (`s3_backfill_batch_{STATE}_*.csv`), skipping recordIDs already terminal; `error` rows are retried. `migration_results/` (in-flight) contributes `copied`+`file_not_found`; `processed_archive/` (finalized) contributes only `file_not_found`, since its `copied` rows are already excluded by `load_work`'s `NOT EXISTS`.
4. `chunk_by_size()` splits the work into fixed-size chunks (`CHUNK_SIZE`, default 2000); a Pebble `ProcessPool` schedules every chunk up front so workers pull the next as they free up (load balancing). Each chunk has a `BATCH_TIMEOUT` (default 1800s) wall-clock limit — a hung share read kills only that chunk, whose unflushed rows retry next run. The worker returns only a counts summary (`copied/file_not_found/error/processed` + CSV path), not per-record rows.
5. Each batch creates its own `S3Client`, and per record: resolves the local path, reads size + (PDF) page count, uploads to S3 (small PDFs read once into a buffer; larger files and verify mode stream), streams the result row to `migration_results/s3_backfill_batch_{STATE}_{N}_{timestamp}_{pid}.csv` (flushed every 100). The time-to-seconds + PID suffix keeps the filename unique across same-day re-runs, so a re-run never truncates a prior run's un-finalized CSV. On an `ExpiredToken` it logs and stops the batch so the rows get retried next run.

**Phase 2 — `python finalize_from_csv.py`:**
1. Reads each batch CSV, batches `status='copied'` rows (`FINALIZE_BATCH_SIZE`, default 1000).
2. Idempotent `INSERT INTO tblS3Image (recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedBy='LND-8093')` guarded by `NOT EXISTS` on the recordID PK.
3. Moves each fully-inserted CSV to `migration_results/processed_archive/` with a UTC timestamp. A CSV with any failed inserts is **left in place** so a re-run retries it (inserts are idempotent).
4. Logs an authoritative `tblS3Image` `COUNT(*)` delta (`before`/`after`/`actually inserted`); the per-CSV figure is "submitted" (rows handed to the `NOT EXISTS` insert), which on re-runs is ≥ the true delta.

## Running

Refresh AWS keys in `.env`, then:

```
# scope/window via env (.env or shell): STATE, ROW_LIMIT, MAX_WORKERS, VERIFY_UPLOADS
python main.py              # phase 1 — upload to S3, write per-batch CSVs
python finalize_from_csv.py # phase 2 — load copied rows into tblS3Image
```

`main.py` refuses `STATE=ALL` with no `ROW_LIMIT` unless `ALLOW_FULL_SCAN=true` (that path builds `STAGE_ALL` ~9M rows in one transaction and loads them all into the parent), and warns when a run loads more than `WARN_WORK_THRESHOLD` (default 1M) records.

Run from a machine with:
- Network access to `\\aus2-cs-fss01.na.drillinginfo.com` (or wherever `storageFilePath` points)
- AWS credentials in `.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) — short-lived; refresh before each run
- ODBC Driver 17 for SQL Server installed

## Done When

- Row count in `tblS3Image` increases by the count of `status='copied'` records (finalize logs the authoritative `COUNT(*)` `before`/`after`/`actually inserted` delta).
- No `status='error'` rows remain in `migration_results/` for records whose file existed on disk.
- `file_not_found` and `error` rows are documented and handed off.

## Handoff notes

- **`copied` does not guarantee a page count.** A successful upload is marked `copied` even if the PDF was corrupt/locked and `pageCount` came back NULL (the file is in S3; only the page count failed). These are queryable after finalize:

  ```sql
  -- PDFs whose page count couldn't be read (corrupt/locked) — distinct from
  -- non-PDFs, which are legitimately NULL because page count is never attempted.
  SELECT recordID, s3FilePath
  FROM countyScansTitle.dbo.tblS3Image
  WHERE _ModifiedBy = 'LND-8093' AND pageCount IS NULL AND s3FilePath LIKE '%.pdf';
  ```

  Hand off that list if a usable page count is required for those records.