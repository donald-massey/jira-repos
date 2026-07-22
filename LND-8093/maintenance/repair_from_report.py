"""
repair_from_report.py
=====================
Sub-task for cleanup_null_metadata.py.

GIVEN:  A cleanup_report_*.csv produced by cleanup_null_metadata.py (dry-run or
        commit) — records known to have metadata issues (pageCount IS NULL or
        fileSizeBytes = 0) that were inserted by the LND-8093 backfill.

EXPECT: For each record in the report, attempt repair:
        1. Look up storageFilePath and fileExtension from tblrecord.
        2. Verify the local file exists on the network share.
        3. Re-read file size and (for PDFs) page count.
        4. Re-upload the file to S3 (replaces any existing object).
        5. UPSERT into tblS3Image — UPDATE if the row still exists, INSERT if it
           was previously deleted by cleanup_null_metadata.py --commit.

        Records that cannot be repaired (file missing, still-corrupt PDF, zero
        bytes on disk) are written to the repair report as 'failed' with a
        reason and are NOT written to tblS3Image.

        Outcomes are written to repair_report_{timestamp}.csv. Dry-run by
        default — pass --commit to apply changes.

Running
-------
1. Ensure AWS credentials in .env are current (they are short-lived).

2. Dry run against a cleanup report CSV:
       python repair_from_report.py cleanup_report_dryrun_20260713T123456Z.csv

3. Review the output repair_report CSV, then commit:
       python repair_from_report.py --commit cleanup_report_dryrun_20260713T123456Z.csv
"""
from __future__ import annotations

import argparse
import csv
import io
import logging
import os
import time
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

logger = logging.getLogger("LND-8093.repair")

BUCKET = "enverus-courthouse-prod-chd-plants"
S3_TABLE = "countyScansTitle.dbo.tblS3Image"
RECORD_TABLE = "countyScansTitle.dbo.tblrecord"
MAX_BUFFER_BYTES = int(os.environ.get("MAX_BUFFER_MB", 100)) * 1024 * 1024

REPAIR_FIELDNAMES = ["recordID", "s3FilePath", "pageCount", "fileSizeBytes", "status", "reason"]


def load_report_csv(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def lookup_source_records(conn, record_ids: list[str]) -> dict[str, dict]:
    """Return {recordID: {storageFilePath, fileExtension}} for the given IDs."""
    if not record_ids:
        return {}
    placeholders = ", ".join(f"'{rid}'" for rid in record_ids)
    rows = conn.execute_query(f"""
        SELECT recordID, storageFilePath, fileExtension
        FROM {RECORD_TABLE}
        WHERE recordID IN ({placeholders})
    """)
    return {r["recordID"]: r for r in rows}


def _pdf_page_count(data: bytes) -> int | None:
    try:
        from pypdf import PdfReader
        return len(PdfReader(io.BytesIO(data)).pages)
    except Exception as exc:
        logger.warning("Page count failed: %s", exc)
        return None


def upsert_s3image(conn, record_id: str, s3_path: str, page_count: int | None, file_size: int) -> None:
    updated = conn.execute_update(f"""
        UPDATE {S3_TABLE}
           SET s3FilePath       = '{s3_path}',
               pageCount        = {'NULL' if page_count is None else page_count},
               fileSizeBytes    = {file_size},
               _ModifiedBy      = 'LND-8093-repair',
               _ModifiedDateTime = GETDATE()
         WHERE recordID = '{record_id}'
    """)
    if updated == 0:
        conn.execute_update(f"""
            INSERT INTO {S3_TABLE} (recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedBy)
            VALUES ('{record_id}', '{s3_path}', {'NULL' if page_count is None else page_count},
                    {file_size}, 'LND-8093-repair')
        """)


def save_repair_report(rows: list[dict], dry_run: bool) -> Path:
    mode = "dryrun" if dry_run else "commit"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = Path(__file__).parent / f"repair_report_{mode}_{stamp}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=REPAIR_FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)
    return path


def run(report_path: Path, dry_run: bool) -> None:
    report_rows = load_report_csv(report_path)
    if not report_rows:
        logger.info("Report CSV is empty — nothing to repair.")
        return

    logger.info("Loaded %d record(s) from %s", len(report_rows), report_path.name)

    conn = connect_countyscanstitle()
    s3 = S3Client(bucket=BUCKET)

    try:
        record_ids = [r["recordID"] for r in report_rows]
        source_map = lookup_source_records(conn, record_ids)
        logger.info("Source lookup returned %d/%d records", len(source_map), len(record_ids))

        results = []
        repaired = failed = 0
        start = time.monotonic()
        last_log = start

        for i, row in enumerate(report_rows, 1):
            record_id = row["recordID"]
            s3_path = row["s3FilePath"]

            result = {
                "recordID": record_id,
                "s3FilePath": s3_path,
                "pageCount": None,
                "fileSizeBytes": None,
                "status": "failed",
                "reason": "",
            }

            source = source_map.get(record_id)
            if not source:
                result["reason"] = "recordID not found in tblrecord"
                results.append(result)
                failed += 1
                continue

            ext = (source.get("fileExtension") or ".pdf").lower()
            local_path = os.path.join(source["storageFilePath"], record_id + ext)

            if not os.path.exists(local_path):
                result["reason"] = f"file not on disk: {local_path}"
                results.append(result)
                failed += 1
                continue

            file_size = os.path.getsize(local_path)
            if file_size == 0:
                result["reason"] = "file is zero bytes on disk"
                results.append(result)
                failed += 1
                continue

            try:
                if ext == ".pdf" and file_size <= MAX_BUFFER_BYTES:
                    with open(local_path, "rb") as fh:
                        data = fh.read()
                    page_count = _pdf_page_count(data)
                    if not dry_run:
                        s3.upload_bytes(data, s3_path)
                    file_size = len(data)
                else:
                    page_count = None
                    if not dry_run:
                        s3.upload_file(local_path, s3_path)

                result["pageCount"] = page_count
                result["fileSizeBytes"] = file_size
                result["status"] = "repaired" if not dry_run else "would_repair"
                result["reason"] = ""

                if not dry_run:
                    upsert_s3image(conn, record_id, s3_path, page_count, file_size)

                repaired += 1

            except ClientError as exc:
                result["reason"] = f"S3 error: {exc}"
                failed += 1
            except Exception as exc:
                result["reason"] = str(exc)
                failed += 1

            results.append(result)

            now = time.monotonic()
            if now - last_log >= 300:
                elapsed = now - start
                rate = i / elapsed if elapsed > 0 else 0
                remaining = len(report_rows) - i
                eta_sec = remaining / rate if rate > 0 else 0
                logger.info(
                    "Processed %d/%d — %.1f rec/s — ETA %dm %02ds | repaired=%d failed=%d",
                    i, len(report_rows), rate, int(eta_sec // 60), int(eta_sec % 60),
                    repaired, failed,
                )
                last_log = now

        report_out = save_repair_report(results, dry_run)
        logger.info(
            "Done — repaired=%d failed=%d | report: %s",
            repaired, failed, report_out,
        )
        if dry_run:
            logger.info("[DRY RUN] No changes applied. Re-run with --commit to write to S3 and DB.")

    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    parser = argparse.ArgumentParser(
        description="Attempt to repair tblS3Image records identified in a cleanup report CSV."
    )
    parser.add_argument("report_csv", type=Path, help="Path to the cleanup_report_*.csv to repair from.")
    parser.add_argument(
        "--commit",
        action="store_true",
        help="Apply repairs. Without this flag the script runs as a dry run.",
    )
    args = parser.parse_args()

    if not args.report_csv.exists():
        raise SystemExit(f"Report CSV not found: {args.report_csv}")

    is_dry_run = not args.commit
    logger.info(
        "Mode: %s | Report: %s | Bucket: %s",
        "DRY RUN" if is_dry_run else "COMMIT", args.report_csv.name, BUCKET,
    )
    run(args.report_csv, is_dry_run)