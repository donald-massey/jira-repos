"""
LND-8482 smoke-test verification — all three prod surfaces in one command.

Run AFTER the single-record --commit smoke test:
    python -m maintenance.repair_from_report artifacts/cleanup_report_commit_20260713T231201Z.csv \
        --commit --record-id f45ec396-8c41-1847-ba38-3b390dbe94a8

Then:
    python query_4/verify_smoke_test.py

Checks the DB (tblrecord + tblS3Image), the S3 object (HEAD, ContentLength vs
fileSizeBytes), and the share (kept .tif + new .pdf). SELECT/HEAD/stat only —
nothing is written. Refresh AWS_* creds first (short-lived).
"""
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from maintenance.repair_from_report import _load_env, BUCKET, REGION  # noqa: E402
_load_env()
from utils.database_utils import connect_countyscanstitle  # noqa: E402
from utils.s3_utils import S3Client  # noqa: E402

RECORD_ID = "f45ec396-8c41-1847-ba38-3b390dbe94a8"
EXPECTED_PAGES = 1
EXPECTED_BYTES = 4629  # exact converted-PDF size from the dry run (Pillow is deterministic)

checks: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    checks.append((name, ok, detail))


def main() -> int:
    conn = connect_countyscanstitle()
    try:
        rec = conn.execute_query(
            "SELECT recordID, fileExtension, statusID, storageFilePath "
            "FROM [countyScansTitle].[dbo].[tblrecord] WHERE recordID = ?",
            [RECORD_ID],
        )
        img = conn.execute_query(
            "SELECT recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedBy "
            "FROM [countyScansTitle].[dbo].[tblS3Image] WHERE recordID = ?",
            [RECORD_ID],
        )
    finally:
        conn.close()

    if not rec:
        check("tblrecord row present", False, "recordID not found")
        return report()
    r = rec[0]
    check("tblrecord.fileExtension == .pdf", r["fileExtension"] == ".pdf", f"got {r['fileExtension']!r}")
    check("tblrecord.statusID == 4 (unchanged)", r["statusID"] == 4, f"got {r['statusID']}")

    if not img:
        check("tblS3Image row present", False, "no row — INSERT branch did not land")
        return report()
    s = img[0]
    check("tblS3Image row present", True)
    check("s3FilePath ends .pdf", str(s["s3FilePath"]).lower().endswith(".pdf"), s["s3FilePath"])
    check("pageCount == 1", s["pageCount"] == EXPECTED_PAGES, f"got {s['pageCount']}")
    check("fileSizeBytes > 0", (s["fileSizeBytes"] or 0) > 0, f"got {s['fileSizeBytes']}")
    check(f"fileSizeBytes == {EXPECTED_BYTES} (exact)", s["fileSizeBytes"] == EXPECTED_BYTES,
          f"got {s['fileSizeBytes']} — nonzero-but-different is a Pillow-version nit, not a failure")
    check("_ModifiedBy == LND-8093-repair", s["_ModifiedBy"] == "LND-8093-repair", f"got {s['_ModifiedBy']!r}")

    # --- S3: HEAD the object the DB points at; ContentLength must match fileSizeBytes ---
    s3 = S3Client(bucket=BUCKET, region=REGION)
    try:
        head = s3.head_object(s["s3FilePath"])
        clen = head["ContentLength"]
        check("S3 object exists (HEAD)", True, f"{clen} bytes")
        check("S3 ContentLength == fileSizeBytes", clen == s["fileSizeBytes"],
              f"S3={clen} DB={s['fileSizeBytes']}")
    except Exception as exc:
        check("S3 object exists (HEAD)", False, str(exc))

    # --- Share: original .tif kept + new .pdf written ---
    storage = r["storageFilePath"]
    tif = os.path.join(storage, RECORD_ID + ".tif")
    pdf = os.path.join(storage, RECORD_ID + ".pdf")
    check("share: original .tif kept", os.path.exists(tif), tif)
    check("share: new .pdf written", os.path.exists(pdf), pdf)

    return report()


def report() -> int:
    print("\n" + "=" * 72)
    print(f"SMOKE-TEST VERIFICATION — {RECORD_ID}")
    print("=" * 72)
    width = max(len(n) for n, _, _ in checks)
    for name, ok, detail in checks:
        tag = "PASS" if ok else "FAIL"
        line = f"[{tag}] {name.ljust(width)}"
        if detail:
            line += f"  ({detail})"
        print(line)
    failed = [n for n, ok, _ in checks if not ok]
    print("-" * 72)
    if failed:
        print(f"RESULT: FAIL — {len(failed)} check(s) failed: {', '.join(failed)}")
        return 1
    print(f"RESULT: PASS — all {len(checks)} checks green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
