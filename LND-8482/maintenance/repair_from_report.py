"""
repair_from_report.py
=====================
LND-8482 — sub-task of LND-8093.

GIVEN:  A cleanup_report_*.csv produced by cleanup_null_metadata.py — tblS3Image
        rows the LND-8093 backfill left with pageCount IS NULL or fileSizeBytes = 0.
        cleanup_null_metadata.py --commit already deleted those rows from S3 and the
        DB; this script re-creates them correctly from the source file on the share.

EXPECT: For each record (scoped to tblrecord.statusID IN (4, 10)):
        1. Look up storageFilePath, fileExtension, statusID from tblrecord.
        2. Read the source file off the network share; sniff its real type by magic
           bytes (not the extension).
        3. TIF  -> convert to PDF with Pillow, then validate the produced PDF with
                   pypdf (page count comes from the PDF, not the TIF frame count).
           PDF  -> if it opens clean, keep it as-is (only metadata was wrong);
                   otherwise ONE pikepdf recovery pass, then re-validate. No looping.
        4. Write the PDF back to the share (non-destructive), upload to S3, then
           upsert tblS3Image + update tblrecord.fileExtension in one transaction.
           DB is always written last so a failure earlier needs no revert.

        Outcomes -> repair_report_{dryrun|commit}_{timestamp}.csv:
          repaired  — TIF converted / PDF recovered / PDF already valid
          skipped   — statusID NOT IN (4, 10)
          failed    — recordID not in tblrecord, file missing, zero bytes, unknown
                      signature, conversion error, validation failure, recovery
                      exhausted, or S3/DB error

        Dry-run by default (still reads + converts + validates to prove the file is
        fixable) — pass --commit to write to the share, S3, and the DB.

Running
-------
1. Ensure AWS credentials in .env are current (they are short-lived).
2. Dry run:   python -m maintenance.repair_from_report artifacts/cleanup_report_commit_*.csv
3. Review the repair_report CSV, then:
   Commit:    python -m maintenance.repair_from_report --commit artifacts/cleanup_report_commit_*.csv
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

from botocore.exceptions import ClientError, NoCredentialsError, CredentialRetrievalError

from utils.database_utils import connect_countyscanstitle
from utils.s3_utils import S3Client


class CredentialsExpired(Exception):
    """Raised when AWS creds die mid-run (e.g. VPN/SSO session lapses).

    Environmental, not per-record: every subsequent record would fail identically,
    so the driver aborts the whole run instead of mass-marking failures for hours.
    """


# S3 error codes that mean the session token is dead — refresh required, no point retrying.
EXPIRED_CRED_CODES = {
    "ExpiredToken", "ExpiredTokenException", "InvalidToken",
    "TokenRefreshRequired", "RequestExpired",
}


def _load_env() -> None:
    try:
        from dotenv import load_dotenv
        env_file = Path(__file__).resolve().parent.parent / ".env"
        if env_file.exists():
            load_dotenv(env_file)
    except ImportError:
        pass


_load_env()

logger = logging.getLogger("LND-8482.repair")

BUCKET = os.environ.get("S3_BUCKET", "enverus-courthouse-prod-chd-plants")
REGION = os.environ.get("AWS_REGION", "us-east-1")
S3_TABLE = "countyScansTitle.dbo.tblS3Image"
RECORD_TABLE = "countyScansTitle.dbo.tblrecord"
IN_SCOPE_STATUS = (4, 10)
MODIFIED_BY = "LND-8093-repair"
MAX_FILE_BYTES = int(os.environ.get("MAX_FILE_MB", 500)) * 1024 * 1024

PDF_MAGIC = b"%PDF"
TIFF_MAGICS = (b"II*\x00", b"MM\x00*")

REPAIR_FIELDNAMES = ["recordID", "s3FilePath", "pageCount", "fileSizeBytes", "status", "kind", "reason"]


# ----------------------------------------------------------------------
# Report I/O
# ----------------------------------------------------------------------

def load_report_csv(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def save_repair_report(rows: list[dict], dry_run: bool) -> Path:
    mode = "dryrun" if dry_run else "commit"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = Path(__file__).resolve().parent.parent / "artifacts" / f"repair_report_{mode}_{stamp}.csv"
    path.parent.mkdir(exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=REPAIR_FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)
    return path


def lookup_source_records(conn, record_ids: list[str]) -> dict[str, dict]:
    """Return {recordID: {storageFilePath, fileExtension, statusID}} for the given IDs."""
    source: dict[str, dict] = {}
    for i in range(0, len(record_ids), 500):
        batch = record_ids[i:i + 500]
        placeholders = ", ".join(f"'{rid}'" for rid in batch)
        rows = conn.execute_query(f"""
            SELECT recordID, storageFilePath, fileExtension, statusID
            FROM {RECORD_TABLE}
            WHERE recordID IN ({placeholders})
        """)
        for r in rows:
            # Key on upper-cased recordID: SQL Server's IN (...) is case-insensitive but
            # the Python dict lookup below is not, so normalise both sides or a casing
            # mismatch between report and tblrecord falsely reports "not found".
            source[r["recordID"].upper()] = r
    return source


# ----------------------------------------------------------------------
# File type + conversion
# ----------------------------------------------------------------------

def sniff_kind(data: bytes) -> str | None:
    """Route on magic bytes, not the extension — the whole defect is bad metadata."""
    head = data[:8]
    if head.startswith(PDF_MAGIC):
        return "pdf"
    if head.startswith(TIFF_MAGICS):
        return "tiff"
    return None


def _pdf_ready(frame):
    """Coerce a TIFF frame into a mode Pillow's PDF encoder accepts, losslessly where possible."""
    if frame.mode in ("1", "L", "RGB", "CMYK"):
        return frame
    return frame.convert("RGB")


def tiff_to_pdf(data: bytes) -> bytes:
    """Convert a (possibly multi-page) TIFF buffer to a PDF buffer via Pillow."""
    from PIL import Image
    with Image.open(io.BytesIO(data)) as img:
        n_frames = getattr(img, "n_frames", 1)
        frames = []
        for i in range(n_frames):
            img.seek(i)
            frames.append(_pdf_ready(img.copy()))
        buf = io.BytesIO()
        frames[0].save(buf, format="PDF", save_all=True, append_images=frames[1:])
        return buf.getvalue()


def validate_pdf(data: bytes) -> int | None:
    """Open PDF bytes with pypdf; return page count if readable and non-empty, else None."""
    try:
        from pypdf import PdfReader
        n = len(PdfReader(io.BytesIO(data)).pages)
        return n if n > 0 else None
    except Exception as exc:
        logger.debug("PDF validation failed: %s", exc)
        return None


def read_or_recover_pdf(data: bytes) -> tuple[bytes, int, str] | None:
    """Return (pdf_bytes, page_count, kind) for a PDF source, or None if unrepairable.

    kind is 'pdf_valid' (opened clean, bytes unchanged) or 'pdf_recovered' (one
    pikepdf recovery pass). Recovery is attempted exactly once — never looped.
    """
    n = validate_pdf(data)
    if n:
        return data, n, "pdf_valid"

    try:
        import pikepdf
        out = io.BytesIO()
        with pikepdf.open(io.BytesIO(data), attempt_recovery=True) as pdf:
            pdf.save(out)
        recovered = out.getvalue()
    except Exception as exc:
        logger.warning("pikepdf recovery failed: %s", exc)
        return None

    n = validate_pdf(recovered)
    if n:
        return recovered, n, "pdf_recovered"
    return None


# ----------------------------------------------------------------------
# Share write-back (non-destructive, crash-safe)
# ----------------------------------------------------------------------

def write_share_pdf(storage_dir: str, record_id: str, orig_ext: str, pdf_bytes: bytes) -> None:
    """Write pdf_bytes as {recordID}.pdf on the share without destroying the source.

    If the source name collides with the target (source was already {recordID}.pdf,
    e.g. a recovered or mislabeled PDF), the original is renamed to {recordID}.old.pdf
    first. Bytes are staged to a temp name and atomically moved into place; the backup
    rename is rolled back on failure so tblrecord never points at a missing file.
    """
    target = os.path.join(storage_dir, record_id + ".pdf")
    source = os.path.join(storage_dir, record_id + orig_ext)
    tmp = os.path.join(storage_dir, record_id + ".pdf.tmp")

    with open(tmp, "wb") as fh:
        fh.write(pdf_bytes)

    backup = None
    if os.path.exists(target) and os.path.abspath(target) == os.path.abspath(source):
        backup = os.path.join(storage_dir, record_id + ".old.pdf")
        os.replace(source, backup)

    try:
        os.replace(tmp, target)
    except Exception:
        if backup and os.path.exists(backup):
            os.replace(backup, source)
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


# ----------------------------------------------------------------------
# DB write (last; single transaction)
# ----------------------------------------------------------------------

def _pdf_s3_key(s3_path: str) -> str:
    """Swap the key's extension to .pdf (TIF -> PDF); a .pdf key is returned unchanged."""
    root, _ = os.path.splitext(s3_path)
    return root + ".pdf"


def commit_db(conn, record_id: str, s3_path: str, page_count: int, file_size: int, update_ext: bool) -> None:
    """Upsert tblS3Image and (for converted TIFs) update tblrecord.fileExtension in one txn.

    The upsert decision is made server-side with @@ROWCOUNT rather than the driver's
    cursor.rowcount: SET NOCOUNT never affects @@ROWCOUNT, so a deleted-then-recreated
    row can't silently skip the INSERT. recordID is the tblS3Image primary key, so the
    UPDATE/INSERT targets exactly one row. Values are parameterised, not interpolated.
    """
    conn.begin_transaction()
    try:
        conn.execute_update(
            f"""
            UPDATE {S3_TABLE}
               SET s3FilePath        = ?,
                   pageCount         = ?,
                   fileSizeBytes     = ?,
                   _ModifiedBy       = ?,
                   _ModifiedDateTime = GETDATE()
             WHERE recordID = ?;
            IF @@ROWCOUNT = 0
                INSERT INTO {S3_TABLE}
                    (recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedBy, _ModifiedDateTime)
                VALUES (?, ?, ?, ?, ?, GETDATE());
            """,
            [s3_path, page_count, file_size, MODIFIED_BY, record_id,
             record_id, s3_path, page_count, file_size, MODIFIED_BY],
        )
        if update_ext:
            # Only fileExtension — tblrecord's tr_tblrecord_PopulateCreatedModified
            # AFTER-UPDATE trigger owns _ModifiedBy/_ModifiedDateTime and would
            # overwrite any stamp we set here. (tblS3Image has no such trigger, so
            # the audit stamp on that write above is real.)
            conn.execute_update(
                f"""
                UPDATE {RECORD_TABLE}
                   SET fileExtension = '.pdf'
                 WHERE recordID = ?
                """,
                [record_id],
            )
        conn.commit()
    except Exception:
        conn.rollback()
        raise


# ----------------------------------------------------------------------
# Per-record repair
# ----------------------------------------------------------------------

def repair_one(row: dict, source: dict | None, conn, s3: S3Client, dry_run: bool) -> dict:
    record_id = row["recordID"]
    result = {
        "recordID": record_id,
        "s3FilePath": row["s3FilePath"],
        "pageCount": None,
        "fileSizeBytes": None,
        "status": "failed",
        "kind": "",
        "reason": "",
    }

    if not source:
        result["reason"] = "recordID not found in tblrecord"
        return result

    status_id = source.get("statusID")
    if status_id not in IN_SCOPE_STATUS:
        result["status"] = "skipped"
        result["reason"] = f"statusID not in {IN_SCOPE_STATUS} (was {status_id})"
        return result

    orig_ext = (source.get("fileExtension") or ".pdf").lower()
    storage_dir = source["storageFilePath"]
    local_path = os.path.join(storage_dir, record_id + orig_ext)

    if not os.path.exists(local_path):
        result["reason"] = f"file not on disk: {local_path}"
        return result

    size_on_disk = os.path.getsize(local_path)
    if size_on_disk == 0:
        result["reason"] = "file is zero bytes on disk"
        return result
    if size_on_disk > MAX_FILE_BYTES:
        result["reason"] = f"file exceeds MAX_FILE_MB ({size_on_disk} bytes)"
        return result

    try:
        with open(local_path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        # A single unreadable file (SMB hiccup, offline/HSM-stubbed file) must not
        # kill the whole run — record it as failed and move on.
        result["reason"] = f"file read error: {exc}"
        return result

    kind = sniff_kind(data)
    if kind is None:
        result["reason"] = "unknown file signature"
        return result

    # Produce the PDF bytes + page count, and decide whether the share needs rewriting.
    if kind == "tiff":
        try:
            pdf_bytes = tiff_to_pdf(data)
        except Exception as exc:
            result["reason"] = f"TIF conversion error: {exc}"
            return result
        page_count = validate_pdf(pdf_bytes)
        if not page_count:
            result["reason"] = "converted PDF failed validation"
            return result
        result["kind"] = "tif_converted"
        write_share = True
    else:  # pdf
        recovered = read_or_recover_pdf(data)
        if recovered is None:
            result["reason"] = "pdf recovery failed"
            return result
        pdf_bytes, page_count, result["kind"] = recovered
        write_share = result["kind"] == "pdf_recovered"  # valid PDFs need no rewrite

    s3_key = _pdf_s3_key(row["s3FilePath"])
    result["s3FilePath"] = s3_key
    result["pageCount"] = page_count
    result["fileSizeBytes"] = len(pdf_bytes)

    if dry_run:
        result["status"] = "would_repair"
        return result

    # Order: share -> S3 -> DB. DB last so an earlier failure needs no revert.
    try:
        if write_share:
            write_share_pdf(storage_dir, record_id, orig_ext, pdf_bytes)
    except Exception as exc:
        result["reason"] = f"share write error: {exc}"
        return result

    try:
        s3.upload_bytes(pdf_bytes, s3_key)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in EXPIRED_CRED_CODES:
            raise CredentialsExpired(f"{code}: {exc}") from exc
        result["reason"] = f"S3 error: {exc}"
        return result
    except (NoCredentialsError, CredentialRetrievalError) as exc:
        raise CredentialsExpired(str(exc)) from exc

    try:
        commit_db(conn, record_id, s3_key, page_count, len(pdf_bytes), update_ext=orig_ext != ".pdf")
    except Exception as exc:
        result["reason"] = f"DB error: {exc}"
        return result

    result["status"] = "repaired"
    return result


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------

def run(report_path: Path, dry_run: bool, limit: int | None = None, record_ids: list[str] | None = None) -> None:
    report_rows = load_report_csv(report_path)
    logger.info("Loaded %d record(s) from %s", len(report_rows), report_path.name)

    # Optional narrowing for smoke tests: pin to specific recordID(s) and/or cap the
    # count. --record-id is matched case-insensitively (report casing can differ).
    if record_ids:
        wanted = {r.strip().upper() for r in record_ids}
        report_rows = [r for r in report_rows if r["recordID"].upper() in wanted]
        logger.info("Filtered to %d row(s) matching %d requested recordID(s)", len(report_rows), len(wanted))
    if limit is not None:
        report_rows = report_rows[:limit]
        logger.info("Limited to first %d row(s)", len(report_rows))

    if not report_rows:
        logger.info("No records to repair after filtering — nothing to do.")
        return

    conn = connect_countyscanstitle()
    # Low retry count: a dead token or dropped VPN should fail fast, not burn ~5 min of
    # exponential backoff per record (run 1 crawled to 2.5 rec/s for exactly this reason).
    s3 = S3Client(bucket=BUCKET, region=REGION, max_attempts=3)

    try:
        record_ids = [r["recordID"] for r in report_rows]
        source_map = lookup_source_records(conn, record_ids)
        logger.info("Source lookup returned %d/%d records", len(source_map), len(record_ids))

        results = []
        counts = {"repaired": 0, "would_repair": 0, "skipped": 0, "failed": 0}
        start = time.monotonic()
        last_log = start

        for i, row in enumerate(report_rows, 1):
            try:
                result = repair_one(row, source_map.get(row["recordID"].upper()), conn, s3, dry_run)
            except CredentialsExpired as exc:
                logger.error(
                    "ABORTING at record %d/%d — AWS credentials expired/unavailable (%s). "
                    "Refresh creds (VPN/SSO) and re-run; %d repaired so far this run.",
                    i, len(report_rows), exc, counts["repaired"],
                )
                break
            counts[result["status"]] = counts.get(result["status"], 0) + 1
            results.append(result)

            now = time.monotonic()
            if now - last_log >= 300:
                elapsed = now - start
                rate = i / elapsed if elapsed > 0 else 0
                remaining = len(report_rows) - i
                eta = remaining / rate if rate > 0 else 0
                logger.info(
                    "Processed %d/%d — %.1f rec/s — ETA %dm %02ds | %s",
                    i, len(report_rows), rate, int(eta // 60), int(eta % 60), counts,
                )
                last_log = now

        report_out = save_repair_report(results, dry_run)
        logger.info("Done — %s | report: %s", counts, report_out)
        if dry_run:
            logger.info("[DRY RUN] No changes applied. Re-run with --commit to write share, S3, and DB.")

    finally:
        conn.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    parser = argparse.ArgumentParser(
        description="Repair tblS3Image records identified in a cleanup report CSV (LND-8482)."
    )
    parser.add_argument("report_csv", type=Path, help="Path to the cleanup_report_*.csv to repair from.")
    parser.add_argument(
        "--commit",
        action="store_true",
        help="Apply repairs to the share, S3, and DB. Without this flag the script runs as a dry run.",
    )
    parser.add_argument(
        "--record-id",
        action="append",
        metavar="ID",
        help="Only process this recordID (repeatable). Use for a single-record --commit smoke test.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Process at most N records (applied after --record-id).",
    )
    args = parser.parse_args()

    if not args.report_csv.exists():
        raise SystemExit(f"Report CSV not found: {args.report_csv}")

    is_dry_run = not args.commit
    logger.info(
        "Mode: %s | Report: %s | Bucket: %s",
        "DRY RUN" if is_dry_run else "COMMIT", args.report_csv.name, BUCKET,
    )
    run(args.report_csv, is_dry_run, limit=args.limit, record_ids=args.record_id)
