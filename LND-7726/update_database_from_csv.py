from __future__ import annotations

import os
import csv
import itertools
import shutil
import logging
from pathlib import Path
from datetime import datetime, timezone
from utils.database_utils import DatabaseConnection

def update_database_from_csv(csv_file_path: str):
    """
    Read migration results from CSV and update database accordingly.
    Rows are processed in batches of BATCH_SIZE (read from the environment,
    defaulting to 1000) to reduce per-row transaction overhead.
    After processing, the CSV is moved to a processed_archive subdirectory
    alongside the source file, with a UTC timestamp appended to the filename.

    Parameters
    ----------
    csv_file_path : path to the CSV file with migration results
    """
    logger = logging.getLogger("LND-7726.db_update")

    batch_size = int(os.environ.get("BATCH_SIZE", 1000))

    # Connect to database
    csd_conn = DatabaseConnection(
        db_name=os.environ.get("CSD_DB", None),
        server=os.environ.get("CSD_SERVER", None),
        username=os.environ.get("CSD_USERNAME", None),
        password=os.environ.get("CSD_PASSWORD", None)
    )
    csd_conn.connect()

    successful_updates = 0
    failed_updates = 0
    rollback_count = 0
    skipped = 0

    # Close the connection no matter how we leave the read loop. Any exception that
    # escapes the loop also skips the archive step below, so the CSV is retained for
    # a clean re-run rather than archived after a partial update.
    try:
        with open(csv_file_path, 'r', encoding='utf-8', newline='') as f:
            reader = csv.DictReader(f)
            batch_num = 0
            while True:
                batch = list(itertools.islice(reader, batch_size))
                if not batch:
                    break
                batch_num += 1

                success_rows = []
                failure_rows = []
                batch_skipped = 0

                for row in batch:
                    raw = (row.get('Processed') or '').strip()
                    try:
                        processed = int(raw)
                    except ValueError:
                        # Malformed/blank Processed cell (e.g. a partially written or
                        # hand-edited CSV). Skip the row rather than aborting the file.
                        logger.warning(
                            "Non-numeric Processed value %r for %s — skipping row.",
                            raw, row.get('record_id'),
                        )
                        skipped += 1
                        batch_skipped += 1
                        continue

                    if processed == 1:
                        success_rows.append(row)
                    elif processed < 0:
                        # Any negative code is a failure (-1 source-missing, -2 other error).
                        failure_rows.append(row)
                    else:
                        logger.warning(
                            f"Unknown Processed value {processed} for {row['record_id']}"
                        )
                        skipped += 1
                        batch_skipped += 1

                # --- Success bucket: one transaction, two executemany calls ---
                batch_successful = 0
                batch_failed = 0

                if success_rows:
                    s3_params = [
                        (row['new_s3_path'], row['record_id']) for row in success_rows
                    ]
                    processed_params = [(row['record_id'],) for row in success_rows]
                    try:
                        csd_conn.begin_transaction()
                        csd_conn.execute_many(
                            "UPDATE CS_Digital.dbo.tblS3Image "
                            "SET s3FilePath = ?, _ModifiedDateTime = GETDATE(), _ModifiedBy = 'LND-7726' "
                            "WHERE recordID = ?",
                            s3_params,
                        )
                        csd_conn.execute_many(
                            "UPDATE CS_Digital.dbo.tblS3Image_LND7726 "
                            "SET Processed = 1 WHERE recordID = ?",
                            processed_params,
                        )
                        csd_conn.commit()
                        batch_successful += len(success_rows)
                        successful_updates += len(success_rows)
                    except Exception as e:
                        csd_conn.rollback()
                        batch_failed += len(success_rows)
                        failed_updates += len(success_rows)
                        # S3 objects for these rows were already moved by process_utils; the DB
                        # was NOT updated. Track this so the CSV is retained (not archived) and
                        # can be reprocessed — the UPDATEs above are idempotent.
                        rollback_count += len(success_rows)
                        record_ids = [row['record_id'] for row in success_rows]
                        logger.error(
                            f"Batch {batch_num}: success-update transaction rolled back for "
                            f"{len(success_rows)} record(s) {record_ids}: {e}"
                        )

                # --- Failure bucket: one transaction, one executemany ---
                # Preserve the row's actual code (-1 vs -2) so the DB keeps the diagnostic
                # distinction and the row is no longer selected by `WHERE Processed = 0`.
                if failure_rows:
                    failure_params = [
                        (int(row['Processed']), row['record_id']) for row in failure_rows
                    ]
                    try:
                        csd_conn.begin_transaction()
                        csd_conn.execute_many(
                            "UPDATE CS_Digital.dbo.tblS3Image_LND7726 "
                            "SET Processed = ? WHERE recordID = ?",
                            failure_params,
                        )
                        csd_conn.commit()
                        batch_failed += len(failure_rows)
                        failed_updates += len(failure_rows)
                    except Exception as e:
                        csd_conn.rollback()
                        # Failure-status flags were not written. Retain the CSV so a re-run
                        # re-applies them (the UPDATE is idempotent); archiving now would let
                        # main.py's dedup skip these rows while they still read Processed = 0.
                        rollback_count += len(failure_rows)
                        record_ids = [row['record_id'] for row in failure_rows]
                        logger.error(
                            f"Batch {batch_num}: failure-status update rolled back for "
                            f"{len(failure_rows)} record(s) {record_ids}: {e}"
                        )

                logger.info(
                    f"Batch {batch_num}: size={len(batch)}, "
                    f"successful={batch_successful}, "
                    f"failed={batch_failed}, "
                    f"skipped={batch_skipped}"
                )
    finally:
        csd_conn.close()

    logger.info("Database update complete:")
    logger.info(f"  Successful: {successful_updates}")
    logger.info(f"  Failed: {failed_updates}")
    logger.info(f"  Rolled back: {rollback_count}")
    logger.info(f"  Skipped: {skipped}")

    # Archive only on a clean run. If any update transaction rolled back, the CSV's
    # record_ids must NOT enter processed_archive/ — main.py's dedup would then skip them
    # forever while their S3 objects are already moved and the DB still points at the old
    # path (or the failure flags were never written). Retain the CSV instead; re-running
    # this (idempotent) updater repairs the DB.
    if rollback_count:
        logger.warning(
            "Retaining CSV (NOT archived): %d record(s) rolled back during a DB update "
            "transaction for %s. Their S3 objects were already moved but the DB was not "
            "fully updated. Re-run this updater (the UPDATEs are idempotent) to recover.",
            rollback_count, csv_file_path,
        )
    else:
        _archive_csv(csv_file_path, logger)


def _archive_csv(csv_file_path: str, logger: logging.Logger) -> None:
    """
    Move a processed CSV into a processed_archive directory that lives
    alongside the source file.  The archived file has a UTC timestamp
    appended to its stem so repeated runs never overwrite each other.

    Parameters
    ----------
    csv_file_path : original path of the CSV that was just processed
    logger        : caller's logger instance
    """
    source = Path(csv_file_path)
    archive_dir = source.parent / "processed_archive"
    archive_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    dest = archive_dir / f"{source.stem}_{timestamp}{source.suffix}"
    shutil.move(str(source), str(dest))
    logger.info(f"Moved processed CSV to: {dest}")


if __name__ == '__main__':

    # Load .env file if python-dotenv is available (local / non-Databricks runs).
    try:
        from dotenv import load_dotenv

        _env_file = Path(__file__).parent / ".env"
        if _env_file.exists():
            load_dotenv(_env_file)
            print(f"Loaded environment variables from {_env_file}")
        else:
            print(f"No .env file found at {_env_file} — using environment / Databricks secrets.")
    except ImportError:
        print("python-dotenv not installed; skipping .env load.")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    target = Path(__file__).parent / "migration_results"
    if target.is_dir():
        csv_files = sorted(target.glob("migration_results_batch_*.csv"))
        if not csv_files:
            print(f"No batch CSV files found in {target}")
        for csv_file in csv_files:
            print(f"Processing: {csv_file.name}")
            try:
                update_database_from_csv(str(csv_file))
            except Exception as exc:
                # Isolate per-file failures so one bad CSV doesn't abort the rest.
                logging.getLogger("LND-7726.db_update").error(
                    "Failed to process %s — continuing with remaining files: %s",
                    csv_file.name, exc,
                )
