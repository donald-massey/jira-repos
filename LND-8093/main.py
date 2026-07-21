"""
main.py
=======
LND-8093 — Backfill CSTitle S3Images (parallel uploader).

Phase 1 of two. Builds a frozen work snapshot, splits the records into
fixed-size chunks load-balanced across a Pebble ProcessPool, and each worker
uploads its files to S3 and streams outcomes to a per-batch CSV in
migration_results/.

Phase 2 (finalize_from_csv.py) reads those CSVs and inserts the successful
uploads into countyScansTitle.dbo.tblS3Image.

Re-runs are safe: the work query excludes rows already in tblS3Image, and
records already recorded as terminal in prior CSVs are skipped.
"""
from __future__ import annotations

import os
import re
import csv
import logging
from pathlib import Path
from datetime import datetime

from pebble import ProcessPool
from concurrent.futures import TimeoutError

from utils.database_utils import connect_countyscanstitle
from utils.process_utils import process_batch, RESULTS_DIR


def _load_env() -> None:
    """Load .env before any module-level config is read (and before workers spawn)."""
    try:
        from dotenv import load_dotenv

        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            load_dotenv(env_file)
    except ImportError:
        pass


_load_env()

# Tunables (env-overridable)
MAX_WORKERS = int(os.environ.get("MAX_WORKERS", 8))
STATE = os.environ.get("STATE", "ALL").upper()          # e.g. "TX"; "ALL" = no state filter
# STATE is interpolated into the staging-table name and the state filter, so whitelist
# it (2-letter abbreviation or ALL) rather than trust the env value verbatim.
if STATE != "ALL" and not re.fullmatch(r"[A-Z]{2}", STATE):
    raise ValueError(f"STATE must be a 2-letter abbreviation or ALL, got {STATE!r}")
ROW_LIMIT = os.environ.get("ROW_LIMIT")                 # optional TOP N window per run
S3_BUCKET = os.environ.get("S3_BUCKET", "enverus-courthouse-prod-chd-plants")
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", 2000))    # files per worker task; smaller = better rebalancing
BATCH_TIMEOUT = int(os.environ.get("BATCH_TIMEOUT", 1800))  # per-chunk wall-clock seconds before the worker is killed
# STATE=ALL with no ROW_LIMIT builds STAGE_ALL (~9M rows) in one SELECT INTO and
# loads them all into the parent. Gate it behind an explicit opt-in, and warn when
# any run loads more than the threshold (high parent memory).
ALLOW_FULL_SCAN = os.environ.get("ALLOW_FULL_SCAN", "false").lower() == "true"
WARN_WORK_THRESHOLD = int(os.environ.get("WARN_WORK_THRESHOLD", 1_000_000))

# LND-6827 county exclusions — leave commented unless Tyler Jordan confirms they apply.

def staging_table_name() -> str:
    """Stable per-state staging table so re-runs reuse one work snapshot."""
    return f"LND_8093_STAGE_{STATE}"


def build_staging_table(conn) -> None:
    """Create the frozen work snapshot via SELECT INTO if it doesn't already exist."""
    table = staging_table_name()
    state_filter = "" if STATE == "ALL" else f"AND tls.stateAbbreviation = '{STATE}'"
    # Resolve NULL/empty fileExtension to '.pdf' — matches process_utils._local_path's
    # default so SQL and Python agree on the key, and keeps s3FilePath NOT NULL
    # (tblS3Image.s3FilePath rejects NULLs, which a NULL extension would produce).
    ext_expr = "COALESCE(NULLIF(tr.fileExtension, ''), '.pdf')"

    sql = f"""
    IF OBJECT_ID('countyScansTitle.scratch.{table}', 'U') IS NULL
    BEGIN
        SELECT
            tr.recordID,
            tr.storageFilePath,
            {ext_expr} AS fileExtension,
            LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '') AS state_countyname,
            's3://{S3_BUCKET}/' + LOWER(tls.stateAbbreviation) + '/' + REPLACE(LOWER(tlc.countyName), '.', '')
                + '/' + LEFT(tr.recordID, 4) + '/' + tr.recordID + {ext_expr} AS s3FilePath
        INTO countyScansTitle.scratch.{table}
        FROM countyScansTitle.dbo.tblrecord tr
        JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.countyID = tr.countyID
        JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.stateID = tr.stateID
        WHERE tr.storageFilePath != 'NONE'
          {state_filter}
          AND NOT EXISTS (
                SELECT 1 FROM countyScansTitle.dbo.tblS3Image s WHERE s.recordID = tr.recordID
              )
        -- Uncomment if LND-6827 exclusions should apply (confirm with Tyler Jordan first):
        -- AND tr.recordIsLease = 1
        -- AND tr.statusID IN (4, 16)
        -- AND tr.fileDate >= '2002-01-01'
        -- AND tr.countyID NOT IN (
        --     288,291,292,293,295,296,298,300,
        --     684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
        --     700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,
        --     1187
        -- )
    END
    """
    logging.getLogger("LND-8093").info("Ensuring staging table %s (state=%s)", table, STATE)
    conn.execute_update(sql)


def load_work(conn) -> list[dict]:
    """Read pending records from staging, excluding any now present in tblS3Image."""
    table = staging_table_name()
    top = f"TOP {int(ROW_LIMIT)}" if ROW_LIMIT else ""
    sql = f"""
        SELECT {top} s.recordID, s.storageFilePath, s.fileExtension, s.state_countyname, s.s3FilePath
        FROM countyScansTitle.scratch.{table} s
        WHERE NOT EXISTS (
            SELECT 1 FROM countyScansTitle.dbo.tblS3Image t WHERE t.recordID = s.recordID
        )
    """
    return conn.execute_query(sql)


def load_already_processed_ids() -> set[str]:
    """Collect recordIDs already terminal in prior CSVs for the current STATE."""
    logger = logging.getLogger("LND-8093")
    seen: set[str] = set()
    # Scope to this STATE's CSVs only (filenames carry the state) so the scan
    # doesn't grow with every other state's history. Per directory:
    #   migration_results/  — in-flight, not yet finalized: 'copied' rows aren't in
    #     tblS3Image yet, so skip both terminal statuses.
    #   processed_archive/  — finalized: 'copied' rows are already excluded by
    #     load_work's NOT EXISTS, so only 'file_not_found' (which never enters
    #     tblS3Image) still needs skipping here.
    dir_terminal = [
        (RESULTS_DIR, {"copied", "file_not_found"}),
        (RESULTS_DIR / "processed_archive", {"file_not_found"}),
    ]
    pattern = f"s3_backfill_batch_{STATE}_*.csv"

    for directory, terminal in dir_terminal:
        if not directory.is_dir():
            continue
        for csv_path in sorted(directory.glob(pattern)):
            try:
                with csv_path.open(newline="", encoding="utf-8") as fh:
                    for row in csv.DictReader(fh):
                        rid = (row.get("recordID") or "").strip()
                        if rid and (row.get("status") or "").strip() in terminal:
                            seen.add(rid)
            except Exception as exc:
                logger.warning("Could not read %s — skipping: %s", csv_path, exc)

    logger.info("Found %d already-processed recordIDs in prior CSVs (state=%s)", len(seen), STATE)
    return seen


def chunk_by_size(items: list, chunk_size: int) -> list[tuple[int, list]]:
    """Split items into fixed-size, batch-numbered chunks so the pool can rebalance across workers."""
    return [
        (i // chunk_size + 1, items[i:i + chunk_size])
        for i in range(0, len(items), chunk_size)
    ]


def main():
    logger = logging.getLogger("LND-8093")
    logger.info("=== LND-8093 backfill | state=%s | workers=%d | chunk=%d | timeout=%ds | row_limit=%s ===",
                STATE, MAX_WORKERS, CHUNK_SIZE, BATCH_TIMEOUT, ROW_LIMIT or "none")

    if STATE == "ALL" and not ROW_LIMIT and not ALLOW_FULL_SCAN:
        raise ValueError(
            "Refusing STATE=ALL with no ROW_LIMIT: this builds STAGE_ALL (~9M rows) in one "
            "transaction and loads them all into the parent. Scope with STATE=<XX>, window with "
            "ROW_LIMIT, or set ALLOW_FULL_SCAN=true to override."
        )

    conn = connect_countyscanstitle()
    try:
        build_staging_table(conn)
        work = load_work(conn)
        logger.info("Loaded %d candidate records from %s", len(work), staging_table_name())
        if len(work) > WARN_WORK_THRESHOLD:
            logger.warning("Loaded %d records (> %d) into the parent — high memory; "
                           "consider tighter STATE/ROW_LIMIT windowing.", len(work), WARN_WORK_THRESHOLD)
    finally:
        conn.close()

    already = load_already_processed_ids()
    if already:
        before = len(work)
        work = [r for r in work if str(r["recordID"]).strip() not in already]
        logger.info("Resume filter: %d skipped, %d remaining", before - len(work), len(work))

    if not work:
        logger.info("Nothing to process. Done.")
        return

    batches = chunk_by_size(work, CHUNK_SIZE)
    logger.info("Split %d records into %d chunks of up to %d", len(work), len(batches), CHUNK_SIZE)

    copied = missing = errored = processed = 0
    start_time = datetime.now()
    with ProcessPool(max_workers=MAX_WORKERS) as pool:
        # Schedule every chunk up front; Pebble queues them and hands the next
        # to whichever worker frees up first (load balancing). Each chunk gets
        # its own wall-clock timeout so one hung SMB read can't stall forever.
        futures = [
            (batch_no, pool.schedule(process_batch, args=[(batch_no, batch)], timeout=BATCH_TIMEOUT))
            for batch_no, batch in batches
        ]
        for batch_no, future in futures:
            try:
                summary = future.result()
            except TimeoutError:
                logger.error("Chunk %d timed out after %ds — its unflushed rows retry next run.",
                             batch_no, BATCH_TIMEOUT)
                continue
            except Exception as e:
                logger.error("Chunk %d failed: %s", batch_no, e)
                continue
            # Workers return only counts + their CSV path (the CSVs are the source
            # of truth); no per-record dicts are pickled back across the pool.
            processed += summary["processed"]
            copied += summary["copied"]
            missing += summary["file_not_found"]
            errored += summary["error"]

    logger.info("Upload phase complete in %s", datetime.now() - start_time)
    logger.info("  copied=%d | file_not_found=%d | error=%d | processed=%d",
                copied, missing, errored, processed)
    logger.info("Next: refresh AWS keys if needed, then run finalize_from_csv.py to load tblS3Image.")


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    main()