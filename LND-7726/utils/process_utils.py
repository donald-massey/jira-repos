from __future__ import annotations  # must be the FIRST import in the file

import os
import csv
import logging
from pathlib import Path
from datetime import datetime
from utils.s3_utils import (
    S3Client,
    copy_and_verify)
from botocore.exceptions import ClientError


def _write_batch_to_csv(batch_results: list[dict], csv_file: Path) -> None:
    """
    Write batch results to a dedicated CSV file (one file per batch).
    No locking needed since each batch writes to its own file.
    """
    logger = logging.getLogger("LND-7726.process_record")
    fieldnames = ['record_id', 'old_s3_path', 'new_s3_path', 'Processed', 'error']

    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for result in batch_results:
            writer.writerow({
                'record_id': result.get('record_id', ''),
                'old_s3_path': result.get('old_s3_path', ''),
                'new_s3_path': result.get('new_s3_path', ''),
                'Processed': result.get('Processed', -1),
                'error': result.get('error', '')
            })

    logger.info("Wrote %d results to %s", len(batch_results), csv_file)


def process_record(batch_tuple):
    """
    Process a batch of records: copy, verify, then delete the old S3 object.
    Must be a top-level function for pickling by multiprocessing.
    Each process creates its own S3 client.

    Parameters
    ----------
    batch_tuple : (batch_number, list[dict]) — batch number and the row dicts
    """
    batch_number, batch = batch_tuple

    logger = logging.getLogger("LND-7726.process_record")
    logger.info("Starting batch %d with %d records", batch_number, len(batch))

    s3_bucket = os.environ.get("S3_BUCKET")
    if not s3_bucket:
        # Fail the batch with a clear message instead of letting boto3 raise a
        # cryptic per-record ParamValidationError against an "s3://None/" path.
        raise RuntimeError("S3_BUCKET environment variable is not set.")
    s3_client = S3Client(bucket=s3_bucket)
    logger.info("S3 client ready: bucket=%s", s3_bucket)

    batch_results = []
    for index, row_dict in enumerate(batch):
        record_id = row_dict["recordID"]
        old_s3_path = row_dict["old_s3FilePath"]
        new_s3_path = row_dict["new_s3FilePath"]

        try:
            # Copy old_s3_path to new_s3_path (raises if the copy or verification fails)
            copy_result = copy_and_verify(client=s3_client, src_key=old_s3_path, dst_key=new_s3_path)
            logger.info("copy_result: %s", copy_result)

            # Delete old_s3_path only after the copy has been verified
            delete_result = s3_client.delete_object(
                Bucket=s3_bucket, Key=old_s3_path.replace(f"s3://{s3_bucket}/", "")
            )
            logger.info("delete_result: %s", delete_result)

            logger.info("record_id: %s status: success", record_id)
            batch_results.append({
                "record_id": record_id,
                "old_s3_path": old_s3_path,
                "new_s3_path": new_s3_path,
                "Processed": 1,  # Success
                "error": ""
            })
        except ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == 'ExpiredToken':
                remaining = len(batch) - index
                logger.error(
                    "Credentials expired on batch %d at record %s; "
                    "%d record(s) left unattempted (will retry next run).",
                    batch_number, record_id, remaining,
                )
                break
            elif error_code == 'NoSuchKey':
                logger.warning("Source file not found for %s: %s", record_id, old_s3_path)
                batch_results.append({
                    "record_id": record_id,
                    "old_s3_path": old_s3_path,
                    "new_s3_path": new_s3_path,
                    "Processed": -1,  # Failed - source not found
                    "error": str(e)
                })
            else:
                logger.error("S3 client error for %s: %s", record_id, e)
                batch_results.append({
                    "record_id": record_id,
                    "old_s3_path": old_s3_path,
                    "new_s3_path": new_s3_path,
                    "Processed": -2,  # Failed - other S3/client error
                    "error": str(e)
                })
        except Exception as e:
            # Any non-ClientError failure — e.g. a failed post-copy verification
            # (copy_and_verify raises FileNotFoundError) or a network error. Record it
            # so the batch CSV is still written and partial progress is never lost.
            logger.error("Unexpected error for %s: %s", record_id, e)
            batch_results.append({
                "record_id": record_id,
                "old_s3_path": old_s3_path,
                "new_s3_path": new_s3_path,
                "Processed": -2,  # Failed - other error
                "error": str(e)
            })

    # Write results to a batch-specific CSV file. The timestamp includes the time so two
    # runs on the same day (before the updater archives) never overwrite each other.
    output_dir = Path("migration_results")
    output_dir.mkdir(exist_ok=True)
    csv_file = output_dir / (
        f"migration_results_batch_{batch_number}_{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.csv"
    )

    _write_batch_to_csv(batch_results, csv_file)

    return batch_results
