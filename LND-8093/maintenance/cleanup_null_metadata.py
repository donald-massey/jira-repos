"""
cleanup_null_metadata.py
========================
Finds tblS3Image rows inserted by LND-8093 where pageCount IS NULL or
fileSizeBytes = 0 (non-PDFs, corrupt PDFs, or zero-byte files), then removes
each record from S3 (if the object exists) and from tblS3Image.

Scope: _ModifiedBy = 'LND-8093' only — does not touch records from other processes.

Dry-run by default — no changes are applied unless --commit is passed.

Running
-------
1. Ensure AWS credentials in .env are current (they are short-lived).

2. Dry run — checks S3 in parallel, logs what would be deleted, writes a report CSV:
       python cleanup_null_metadata.py

3. Review the report CSV in the project root, then commit (reuses the S3 check
   results from step 2 — no second S3 sweep):
       python cleanup_null_metadata.py --commit --report-csv cleanup_report_dryrun_20260713T123456Z.csv

   Or commit without a prior dry run (re-checks S3 from scratch):
       python cleanup_null_metadata.py --commit

The script deletes S3 objects first. If any S3 delete fails it aborts before
touching the DB, so no DB rows are orphaned. The report CSV is written in both
modes and named cleanup_report_{dryrun|commit}_{timestamp}.csv.

S3 existence checks run in parallel (default 20 workers; override with
S3_CHECK_WORKERS env var).
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

from botocore.exceptions import ClientError

from utils.database_utils import connect_countyscanstitle
from utils.s3_utils import S3Client


def _load_env() -> None:
    try:
        from dotenv import load_dotenv
        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            load_dotenv(env_file)
    except ImportError:
        pass


_load_env()

logger = logging.getLogger("LND-8093.cleanup")

BUCKET = "enverus-courthouse-prod-chd-plants"
TABLE = "countyScansTitle.dbo.tblS3Image"
BATCH_SIZE = 500
S3_CHECK_WORKERS = int(os.environ.get("S3_CHECK_WORKERS", 20))


def get_null_metadata_records(conn) -> list[dict]:
    return conn.execute_query(f"""
        SELECT recordID, s3FilePath, pageCount, fileSizeBytes
        FROM {TABLE}
        WHERE _ModifiedBy = 'LND-8093'
          AND (pageCount IS NULL OR fileSizeBytes = 0)
    """)


def _check_one(s3: S3Client, row: dict) -> tuple[dict, bool]:
    """Return (row, exists) for use in the parallel check pool."""
    try:
        s3.head_object(row["s3FilePath"])
        return row, True
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey"):
            return row, False
        raise


def check_s3_exists_parallel(
    s3: S3Client, rows: list[dict], max_workers: int = S3_CHECK_WORKERS
) -> tuple[list[dict], list[dict]]:
    """HEAD-check all rows concurrently; return (exists_rows, missing_rows)."""
    s3_exists_rows: list[dict] = []
    s3_missing_rows: list[dict] = []
    total = len(rows)
    completed = 0

    check_start = time.monotonic()
    last_log = check_start

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_check_one, s3, row): row for row in rows}
        for future in as_completed(futures):
            row, exists = future.result()  # propagates non-404 ClientErrors
            row["s3_existed"] = exists
            (s3_exists_rows if exists else s3_missing_rows).append(row)
            completed += 1

            now = time.monotonic()
            if now - last_log >= 300:
                elapsed = now - check_start
                rate = completed / elapsed if elapsed > 0 else 0
                remaining = total - completed
                eta_sec = remaining / rate if rate > 0 else 0
                logger.info(
                    "S3 checked %d/%d — %.1f rec/s — ETA %dm %02ds",
                    completed, total, rate, int(eta_sec // 60), int(eta_sec % 60),
                )
                last_log = now

    return s3_exists_rows, s3_missing_rows


def load_report_s3_status(report_csv: Path) -> tuple[list[dict], list[dict]]:
    """Read S3 existence results from a prior dry-run report; skip the HEAD sweep."""
    rows = []
    with report_csv.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            row["s3_existed"] = row.get("s3_existed", "").lower() in ("true", "1", "yes")
            rows.append(row)
    s3_exists_rows = [r for r in rows if r["s3_existed"]]
    s3_missing_rows = [r for r in rows if not r["s3_existed"]]
    return s3_exists_rows, s3_missing_rows


def delete_db_records(conn, record_ids: list[str]) -> int:
    deleted = 0
    for i in range(0, len(record_ids), BATCH_SIZE):
        batch = record_ids[i:i + BATCH_SIZE]
        placeholders = ", ".join(f"'{rid}'" for rid in batch)
        deleted += conn.execute_update(f"DELETE FROM {TABLE} WHERE recordID IN ({placeholders})")
    return deleted


def save_report(rows: list[dict], dry_run: bool) -> Path:
    mode = "dryrun" if dry_run else "commit"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = Path(__file__).parent / f"cleanup_report_{mode}_{stamp}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=["recordID", "s3FilePath", "pageCount", "fileSizeBytes", "s3_existed"])
        writer.writeheader()
        writer.writerows(rows)
    return path


def run(dry_run: bool, report_csv: Path | None = None) -> None:
    conn = connect_countyscanstitle()
    s3 = S3Client(bucket=BUCKET)

    try:
        rows = get_null_metadata_records(conn)
        logger.info("Found %d record(s) in %s with null pageCount or fileSizeBytes=0", len(rows), TABLE)

        if not rows:
            logger.info("Nothing to clean up.")
            return

        if report_csv:
            logger.info("Loading S3 status from prior report: %s", report_csv.name)
            s3_exists_rows, s3_missing_rows = load_report_s3_status(report_csv)
            logger.info("Loaded — exists=%d missing=%d", len(s3_exists_rows), len(s3_missing_rows))
        else:
            logger.info("Checking S3 existence with %d workers…", S3_CHECK_WORKERS)
            s3_exists_rows, s3_missing_rows = check_s3_exists_parallel(s3, rows)

        logger.info("Object EXISTS in S3  (delete from S3 + DB): %d", len(s3_exists_rows))
        for r in s3_exists_rows:
            logger.info("  EXISTS   %s  %s", r["recordID"], r["s3FilePath"])

        logger.info("Object MISSING in S3 (delete from DB only): %d", len(s3_missing_rows))
        for r in s3_missing_rows:
            logger.info("  MISSING  %s", r["recordID"])

        report_path = save_report(s3_exists_rows + s3_missing_rows, dry_run)
        logger.info("Report saved: %s", report_path)

        if dry_run:
            logger.info("[DRY RUN] No changes applied. Re-run with --commit to delete.")
            return

        if s3_exists_rows:
            keys = [r["s3FilePath"] for r in s3_exists_rows]
            failed_keys: list[str] = []
            for i in range(0, len(keys), 1000):
                batch = keys[i:i + 1000]
                errors = s3.delete_objects(batch)
                failed_keys.extend(errors)
                logger.info("S3 batch deleted %d keys (offset %d)", len(batch) - len(errors), i)

            if failed_keys:
                logger.error(
                    "%d S3 delete(s) failed — aborting before DB deletes to avoid orphaned records: %s",
                    len(failed_keys), failed_keys[:10],
                )
                return

        all_ids = [r["recordID"] for r in s3_exists_rows + s3_missing_rows]
        deleted = delete_db_records(conn, all_ids)
        logger.info("Deleted %d row(s) from %s", deleted, TABLE)

    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    parser = argparse.ArgumentParser(
        description="Remove tblS3Image rows with null pageCount/fileSizeBytes and their S3 objects."
    )
    parser.add_argument(
        "--commit",
        action="store_true",
        help="Apply deletes. Without this flag the script runs as a dry run.",
    )
    parser.add_argument(
        "--report-csv",
        type=Path,
        default=None,
        metavar="PATH",
        help="Path to a prior cleanup_report_dryrun_*.csv — reuses its S3 existence "
             "results instead of re-checking S3. Only valid with --commit.",
    )
    args = parser.parse_args()

    if args.report_csv and not args.commit:
        parser.error("--report-csv is only useful with --commit (dry run always checks S3 fresh).")
    if args.report_csv and not args.report_csv.exists():
        raise SystemExit(f"Report CSV not found: {args.report_csv}")

    dry_run = not args.commit
    logger.info(
        "Mode: %s | Table: %s | Bucket: %s | S3_CHECK_WORKERS: %d",
        "DRY RUN" if dry_run else "COMMIT", TABLE, BUCKET, S3_CHECK_WORKERS,
    )
    run(dry_run, args.report_csv)
