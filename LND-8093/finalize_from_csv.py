"""
finalize_from_csv.py
====================
Phase 2 of the LND-8093 backfill.

Reads the per-batch result CSVs written by main.py and inserts every
status='copied' row into countyScansTitle.dbo.tblS3Image. Inserts are
idempotent (guarded by NOT EXISTS on the recordID primary key) so re-running
is safe. Processed CSVs are moved to migration_results/processed_archive/.

Ported from LND-7726 update_database_from_csv.py and adapted to INSERT into
tblS3Image rather than UPDATE.
"""
from __future__ import annotations

import os
import csv
import shutil
import logging
import itertools
from pathlib import Path
from datetime import datetime, timezone

from utils.database_utils import connect_countyscanstitle


def _load_env() -> None:
    """Load .env before any module-level config is read."""
    try:
        from dotenv import load_dotenv

        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            load_dotenv(env_file)
    except ImportError:
        pass


_load_env()

RESULTS_DIR = Path(__file__).parent / "migration_results"
BATCH_SIZE = int(os.environ.get("FINALIZE_BATCH_SIZE", 1000))
MODIFIED_BY = "LND-8093"

INSERT_SQL = """
    INSERT INTO countyScansTitle.dbo.tblS3Image
        (recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedBy)
    SELECT ?, ?, ?, ?, ?
    WHERE NOT EXISTS (
        SELECT 1 FROM countyScansTitle.dbo.tblS3Image WHERE recordID = ?
    )
"""


def _to_int(value):
    value = (value or "").strip()
    return int(value) if value else None


def finalize_csv(conn, csv_file: Path) -> tuple[int, int, int]:
    """Insert this file's copied rows into tblS3Image; return (submitted, skipped_status, errors)."""
    logger = logging.getLogger("LND-8093.finalize")
    submitted = skipped = errors = 0

    with csv_file.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        while True:
            chunk = list(itertools.islice(reader, BATCH_SIZE))
            if not chunk:
                break

            params = []
            for row in chunk:
                if (row.get("status") or "").strip() != "copied":
                    skipped += 1
                    continue
                rid = row["recordID"]
                params.append((
                    rid,
                    row["s3FilePath"],
                    _to_int(row.get("pageCount")),
                    _to_int(row.get("fileSizeBytes")),
                    MODIFIED_BY,
                    rid,  # NOT EXISTS guard
                ))

            if params:
                try:
                    conn.begin_transaction()
                    conn.execute_many(INSERT_SQL, params)
                    conn.commit()
                    # Rows *submitted*; the NOT EXISTS guard means actual inserts may
                    # be fewer (already present). Authoritative count is the table delta in main().
                    submitted += len(params)
                except Exception as e:
                    conn.rollback()
                    errors += len(params)
                    logger.error("Insert batch from %s rolled back (%d rows): %s",
                                 csv_file.name, len(params), e)

    logger.info("%s: submitted=%d skipped=%d errors=%d", csv_file.name, submitted, skipped, errors)
    return submitted, skipped, errors


def _table_count(conn) -> int:
    """Current tblS3Image row count — bracketing this gives the true insert delta."""
    rows = conn.execute_query("SELECT COUNT(*) AS n FROM countyScansTitle.dbo.tblS3Image")
    return rows[0]["n"] if rows else 0


def archive_csv(csv_file: Path) -> None:
    """Move a processed CSV into processed_archive/ with a UTC timestamp suffix."""
    archive_dir = csv_file.parent / "processed_archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    stamped = f"{csv_file.stem}_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}{csv_file.suffix}"
    shutil.move(str(csv_file), str(archive_dir / stamped))


def main():
    logger = logging.getLogger("LND-8093.finalize")
    if not RESULTS_DIR.is_dir():
        logger.info("No migration_results/ directory — nothing to finalize.")
        return

    csv_files = sorted(RESULTS_DIR.glob("s3_backfill_batch_*.csv"))
    if not csv_files:
        logger.info("No batch CSVs to finalize in %s", RESULTS_DIR)
        return

    conn = connect_countyscanstitle()
    totals = [0, 0, 0]
    count_before = count_after = 0
    try:
        count_before = _table_count(conn)
        for csv_file in csv_files:
            logger.info("Finalizing %s", csv_file.name)
            sub, skp, err = finalize_csv(conn, csv_file)
            totals[0] += sub
            totals[1] += skp
            totals[2] += err
            if err:
                logger.warning("%s left in place (%d row(s) failed to insert) — re-run finalize "
                               "to retry; inserts are idempotent.", csv_file.name, err)
            else:
                archive_csv(csv_file)
        count_after = _table_count(conn)
    finally:
        conn.close()

    logger.info("Finalize complete: submitted=%d | skipped(non-copied)=%d | errors=%d", *totals)
    logger.info("tblS3Image rows: before=%d after=%d (actually inserted=%d)",
                count_before, count_after, count_after - count_before)
    if totals[2]:
        logger.warning("%d rows failed to insert — review logs before re-running.", totals[2])


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    main()