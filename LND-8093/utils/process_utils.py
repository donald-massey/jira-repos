"""
process_utils.py
================
Per-worker batch processor for the LND-8093 S3Image backfill.

Each worker gets one chunk of records, and for every record:
  1. resolves the local file path on the network share,
  2. reads file size and (for PDFs) page count,
  3. uploads the file to S3,
  4. records the outcome.

To avoid touching each file twice over the share, a PDF at or below
MAX_BUFFER_BYTES (and not in verify mode) is read once into memory — page count
and upload both come from that one buffer. Larger files and verify mode stream
(separate page-count read + upload).

Results are streamed to a per-batch CSV so a crash or expired token never
loses more than the rows since the last flush; the worker returns only a small
counts summary (not the per-record rows), since the CSV is the source of truth.
Ported from LND-7726 (vm_mod_claude-improvements).
"""
from __future__ import annotations

import io
import os
import csv
import logging
from pathlib import Path
from datetime import datetime

from botocore.exceptions import ClientError

from utils.s3_utils import S3Client

RESULTS_DIR = Path(__file__).resolve().parent.parent / "migration_results"  # <project>/migration_results
CSV_FIELDNAMES = ["recordID", "s3FilePath", "pageCount", "fileSizeBytes", "status", "error"]
FLUSH_EVERY = 100

# State scopes the CSV filename so per-state runs don't collide and the resume
# scan in main.py can glob just this state's CSVs (inherited via spawned env).
STATE = os.environ.get("STATE", "ALL").upper()

# PDFs at or below this size are read once into memory (page count + upload share
# one buffer) instead of opened twice over the share. Larger files stream.
MAX_BUFFER_BYTES = int(os.environ.get("MAX_BUFFER_MB", 100)) * 1024 * 1024

# Token-expiry / credential-failure codes that should stop the whole batch.
EXPIRED_TOKEN_CODES = {"ExpiredToken", "ExpiredTokenException", "RequestExpired", "InvalidToken"}


def _pdf_reader():
    from pypdf import PdfReader  # noqa: PLC0415
    return PdfReader


def _get_pdf_page_count(local_path: str) -> int | None:
    """Return the PDF page count, or None if it can't be read."""
    try:
        return len(_pdf_reader()(local_path).pages)
    except Exception as exc:  # corrupt/locked PDF — log and continue
        logging.getLogger("LND-8093.process").warning("Page count failed for %s: %s", local_path, exc)
        return None


def _pdf_page_count_from_bytes(data: bytes) -> int | None:
    """Return the PDF page count from an in-memory buffer, or None if it can't be read."""
    try:
        return len(_pdf_reader()(io.BytesIO(data)).pages)
    except Exception as exc:  # corrupt PDF — log and continue
        logging.getLogger("LND-8093.process").warning("Page count failed (in-memory): %s", exc)
        return None


def _local_path(row: dict) -> str:
    ext = row.get("fileExtension") or ".pdf"
    return os.path.join(row["storageFilePath"], row["recordID"] + ext)


def process_batch(batch_tuple) -> dict:
    """Upload one (batch_number, rows) chunk to S3, streaming results to its own CSV; return counts."""
    batch_number, batch = batch_tuple
    logger = logging.getLogger("LND-8093.process")
    logger.info("Starting batch %d with %d records", batch_number, len(batch))

    s3_bucket = os.environ.get("S3_BUCKET", "enverus-courthouse-prod-chd-plants")
    region = os.environ.get("AWS_REGION", "us-east-1")
    verify = os.environ.get("VERIFY_UPLOADS", "false").lower() == "true"
    s3_client = S3Client(bucket=s3_bucket, region=region)

    RESULTS_DIR.mkdir(exist_ok=True)
    # Time-to-seconds + PID keep the filename unique across same-day re-runs and
    # concurrent workers, so a re-run can't truncate a prior run's un-finalized CSV
    # (re-chunking remaps batch_number to different records). Stale CSVs just pile
    # up in migration_results/ until finalize archives them — safe, never overwritten.
    stamp = datetime.now().strftime("%Y-%m-%dT%H%M%S")
    csv_path = RESULTS_DIR / f"s3_backfill_batch_{STATE}_{batch_number}_{stamp}_{os.getpid()}.csv"

    counts = {"copied": 0, "file_not_found": 0, "error": 0}
    start_time = datetime.now()

    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDNAMES)
        writer.writeheader()

        for counter, row in enumerate(batch, 1):
            record_id = row["recordID"]
            s3_path = row["s3FilePath"]
            local_path = _local_path(row)
            ext = (row.get("fileExtension") or ".pdf").lower()

            result = {
                "recordID": record_id,
                "s3FilePath": s3_path,
                "pageCount": None,
                "fileSizeBytes": None,
                "status": "error",
                "error": "",
            }

            try:
                if not os.path.exists(local_path):
                    result["status"] = "file_not_found"
                    result["error"] = f"not on disk: {local_path}"
                else:
                    file_size = os.path.getsize(local_path)
                    result["fileSizeBytes"] = file_size
                    if ext == ".pdf" and not verify and file_size <= MAX_BUFFER_BYTES:
                        # Read once off the share: page count + upload share the buffer.
                        with open(local_path, "rb") as pdf_fh:
                            data = pdf_fh.read()
                        result["pageCount"] = _pdf_page_count_from_bytes(data)
                        s3_client.upload_bytes(data, s3_path)
                        result["fileSizeBytes"] = len(data)
                    else:
                        # Streaming path: non-PDF, verify mode, or a file too big to buffer.
                        if ext == ".pdf":
                            result["pageCount"] = _get_pdf_page_count(local_path)
                        result["fileSizeBytes"] = s3_client.upload_and_verify(local_path, s3_path) if verify \
                            else (s3_client.upload_file(local_path, s3_path) or file_size)
                    result["status"] = "copied"
            except ClientError as e:
                code = e.response.get("Error", {}).get("Code", "")
                result["error"] = str(e)
                if code in EXPIRED_TOKEN_CODES:
                    logger.error("Batch %d: AWS credentials expired (%s) — stopping batch. "
                                 "Refresh AWS keys and re-run; finished records will be skipped.",
                                 batch_number, code)
                    # Don't record this record as terminal — leave it to be retried on re-run.
                    break
                logger.warning("recordID %s S3 error: %s", record_id, e)
            except Exception as e:
                result["error"] = str(e)
                logger.warning("recordID %s failed: %s", record_id, e)

            try:
                writer.writerow(result)
                counts[result["status"]] = counts.get(result["status"], 0) + 1
                if counter % FLUSH_EVERY == 0:
                    fh.flush()
                    elapsed = datetime.now() - start_time
                    logger.info("Batch %d: %d/%d rows | elapsed %s", batch_number, counter, len(batch), elapsed)
            except Exception as write_exc:
                logger.error("Batch %d: CSV write failed for recordID %s: %s — row lost",
                             batch_number, record_id, write_exc)

    processed = sum(counts.values())
    logger.info("Batch %d done: %d copied of %d processed -> %s",
                batch_number, counts["copied"], processed, csv_path.name)
    return {
        "batch_number": batch_number,
        "copied": counts["copied"],
        "file_not_found": counts["file_not_found"],
        "error": counts["error"],
        "processed": processed,
        "csv_path": str(csv_path),
    }