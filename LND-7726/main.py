from __future__ import annotations  # must be the FIRST import in the file

import csv
import os
import logging
from pathlib import Path
from datetime import datetime
from pebble import ProcessPool
from concurrent.futures import TimeoutError

from utils.process_utils import process_record
from utils.database_utils import DatabaseConnection


def _load_already_processed_ids() -> set[str]:
    """Return the set of record_ids that already appear in any migration-results CSV.

    Scans two locations relative to this file:
      - migration_results/migration_results_batch_*.csv          (in-flight / unprocessed)
      - migration_results/processed_archive/migration_results_batch_*.csv  (already archived)

    Any row whose ``record_id`` column is non-empty is included so that re-runs
    never re-queue work that has already been attempted.
    """
    logger = logging.getLogger("LND-7726.main")
    base = Path(__file__).parent / "migration_results"

    search_dirs = [
        base,
        base / "processed_archive",
    ]

    seen_ids: set[str] = set()
    for directory in search_dirs:
        if not directory.is_dir():
            continue
        for csv_path in sorted(directory.glob("migration_results_batch_*.csv")):
            try:
                with csv_path.open(newline="", encoding="utf-8") as fh:
                    reader = csv.DictReader(fh)
                    for row in reader:
                        rid = row.get("record_id", "").strip()
                        if rid:
                            seen_ids.add(rid)
            except Exception as exc:
                logger.warning("Could not read %s — skipping: %s", csv_path, exc)

    logger.info("Found %d already-processed record IDs in migration_results CSVs", len(seen_ids))
    return seen_ids


def main():

    logger = logging.getLogger("LND-7726.main")
    MAX_WORKERS = 8  # Adjust based on your system/resources

    def get_db_connection(*, db_name: str, server: str, username: str = "",
                          password: str = "") -> DatabaseConnection:
        """Return a live pyodbc database connection using explicit keyword arguments."""
        conn = DatabaseConnection(
            db_name=db_name,
            server=server,
            username=username,
            password=password,
        )
        conn.connect()
        return conn

    # Only the CS_Digital database is processed in this migration.
    CS_Digital = get_db_connection(
        db_name=os.environ.get("CSD_DB"),
        server=os.environ.get("CSD_SERVER"),
        username=os.environ.get("CSD_USERNAME"),
        password=os.environ.get("CSD_PASSWORD"),
    )

    DATABASES = {"CSD_DB": CS_Digital}
    logger.info("Database connections ready: %s", list(DATABASES.keys()))

    csd_conn = DATABASES["CSD_DB"]
    csd_list = csd_conn.execute_query("SELECT * FROM tblS3Image_LND7726 WHERE Processed = 0", params=[])
    csd_conn.close()

    # ------------------------------------------------------------------
    # Filter out records that already appear in migration-results CSVs
    # (both in-flight and archived) so that re-runs never re-queue work
    # that has already been attempted in a previous run.
    # ------------------------------------------------------------------
    already_processed = _load_already_processed_ids()
    if already_processed:
        before = len(csd_list)
        csd_list = [r for r in csd_list if str(r.get("recordID", "")).strip() not in already_processed]
        skipped = before - len(csd_list)
        logger.info(
            "Filtered csd_list: %d record(s) skipped (already in migration CSVs), %d remaining",
            skipped,
            len(csd_list),
        )

    def chunk_list(items, num_chunks):
        """Split items into exactly num_chunks batches, stamping each with a batch number.

        Items are distributed as evenly as possible across batches using divmod, so the
        number of output batches always equals min(num_chunks, len(items)) — guaranteeing
        at most num_chunks CSV files regardless of how many records are returned.
        """
        if not items:
            return []
        actual_chunks = min(num_chunks, len(items))
        base_size, remainder = divmod(len(items), actual_chunks)
        batches = []
        start = 0
        for chunk_idx in range(actual_chunks):
            size = base_size + (1 if chunk_idx < remainder else 0)
            batches.append((chunk_idx + 1, items[start:start + size]))
            start += size
        return batches

    batched_list = chunk_list(csd_list, num_chunks=MAX_WORKERS)
    logger.info(f"Split {len(csd_list)} records into {len(batched_list)} batches")

    results = []
    start_time = datetime.now()
    with ProcessPool(max_workers=MAX_WORKERS) as pool:
        future = pool.map(process_record, batched_list)
        iterator = future.result()

        while True:
            try:
                batch_result = next(iterator)
                logger.info(f"Completed batch with {len(batch_result)} records")
                results.extend(batch_result)
            except StopIteration:
                break
            except TimeoutError as e:
                logger.error(f"Batch timed out: {e}")
                results.append({"status": "timeout", "error": str(e)})
            except Exception as e:
                logger.error(f"Batch failed: {e}")
                results.append({"status": "error", "error": str(e)})

    succeeded = sum(1 for r in results if r.get("Processed") == 1)
    failed = sum(1 for r in results if r.get("Processed") in (-1, -2))
    batch_errors = sum(1 for r in results if r.get("status") in ("timeout", "error"))
    logger.info(
        "Processing complete: %d succeeded, %d failed, %d batch-level error(s) out of %d total",
        succeeded, failed, batch_errors, len(csd_list),
    )
    logger.info(f"Elapsed Time: {datetime.now() - start_time}")


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
    logger = logging.getLogger("LND-7726")
    logger.info("Logging initialised.")

    main()
