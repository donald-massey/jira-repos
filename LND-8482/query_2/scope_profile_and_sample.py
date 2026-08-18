"""
scope_profile_and_sample.py
===========================
LND-8482 — join the full cleanup_report to tblrecord ONCE, then:

  (a) profile the statusID distribution across all 155k candidates so we know the
      true in-scope workload (statusID IN (4,10)); writes statusid_profile.csv.
  (b) draw a balanced 100-row sample restricted to in-scope records, stratified by
      the AUTHORITATIVE tblrecord.fileExtension (not the S3-path extension, which
      the dry run proved can lie). Writes sample_scoped_100.csv.

Why this supersedes query_1's sampler: query_1 stratified on the S3-path extension,
which is knowable from the CSV alone but aligns with neither the scope gate
(statusID) nor the real routing (magic bytes). The result was 74% out-of-scope and
zero in-scope coverage of the TIF and zero-byte paths. This sampler gates on scope
first, so every sampled record actually exercises a repair path.

In-scope strata (tblrecord.fileExtension + the report's recorded defect):
  ext_tif       — fileExtension .tif/.tiff
  ext_pdf_zero  — fileExtension .pdf AND report fileSizeBytes == 0
  ext_pdf_null  — fileExtension .pdf AND report fileSizeBytes > 0

    python query_2/scope_profile_and_sample.py \
        artifacts/cleanup_report_commit_20260713T231201Z.csv \
        --n 100 \
        --profile-out query_2/statusid_profile.csv \
        --sample-out  query_2/sample_scoped_100.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils.database_utils import connect_countyscanstitle  # noqa: E402

SEED = 8482
IN_SCOPE_STATUS = (4, 10)
RECORD_TABLE = "countyScansTitle.dbo.tblrecord"
STRATA = ("ext_tif", "ext_pdf_zero", "ext_pdf_null")


def _load_env() -> None:
    try:
        from dotenv import load_dotenv
        env = Path(__file__).resolve().parent.parent / ".env"
        if env.exists():
            load_dotenv(env)
    except ImportError:
        pass


def load_report(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def join_tblrecord(conn, record_ids: list[str]) -> dict[str, dict]:
    """Return {UPPER(recordID): {statusID, fileExtension, storageFilePath}}."""
    out: dict[str, dict] = {}
    total = len(record_ids)
    for i in range(0, total, 500):
        batch = record_ids[i:i + 500]
        placeholders = ", ".join(f"'{r}'" for r in batch)
        rows = conn.execute_query(f"""
            SELECT recordID, statusID, fileExtension, storageFilePath
            FROM {RECORD_TABLE}
            WHERE recordID IN ({placeholders})
        """)
        for r in rows:
            out[r["recordID"].upper()] = r
        if (i // 500) % 20 == 0:
            print(f"  joined {min(i + 500, total):,}/{total:,}", file=sys.stderr)
    return out


def stratum_of(fileExtension: str | None, report_size: str | None) -> str | None:
    ext = (fileExtension or "").lower()
    if ext in (".tif", ".tiff"):
        return "ext_tif"
    if ext == ".pdf":
        try:
            size = int(report_size or 0)
        except ValueError:
            size = 0
        return "ext_pdf_zero" if size == 0 else "ext_pdf_null"
    return None  # other / missing extension


def allocate(n: int, strata: list[str]) -> dict[str, int]:
    base, extra = divmod(n, len(strata))
    return {s: base + (1 if i < extra else 0) for i, s in enumerate(strata)}


def main() -> None:
    ap = argparse.ArgumentParser(description="Scope profile + in-scope stratified sample (LND-8482).")
    ap.add_argument("report_csv", type=Path)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--profile-out", type=Path, default=Path("query_2/statusid_profile.csv"))
    ap.add_argument("--sample-out", type=Path, default=Path("query_2/sample_scoped_100.csv"))
    args = ap.parse_args()

    _load_env()
    report = load_report(args.report_csv)
    fieldnames = list(report[0].keys())
    record_ids = [r["recordID"] for r in report]
    print(f"Loaded {len(report):,} candidates from {args.report_csv.name}")

    conn = connect_countyscanstitle()
    try:
        joined = join_tblrecord(conn, record_ids)
    finally:
        conn.close()
    print(f"tblrecord join returned {len(joined):,}/{len(record_ids):,}")

    # ---- (a) statusID profile ----
    status_counts: Counter = Counter()
    not_found = 0
    for r in report:
        rec = joined.get(r["recordID"].upper())
        if rec is None:
            not_found += 1
            continue
        status_counts[rec["statusID"]] += 1

    args.profile_out.parent.mkdir(parents=True, exist_ok=True)
    with args.profile_out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["statusID", "count", "in_scope"])
        for status, n in sorted(status_counts.items(), key=lambda kv: -kv[1]):
            w.writerow([status, n, status in IN_SCOPE_STATUS])
        w.writerow(["<not_found_in_tblrecord>", not_found, False])

    in_scope_total = sum(n for s, n in status_counts.items() if s in IN_SCOPE_STATUS)
    print(f"\n=== statusID profile ({args.profile_out}) ===")
    print(f"{'statusID':>10s} {'count':>9s}  in-scope")
    for status, n in sorted(status_counts.items(), key=lambda kv: -kv[1]):
        print(f"{str(status):>10s} {n:>9,}  {'YES' if status in IN_SCOPE_STATUS else ''}")
    if not_found:
        print(f"{'<none>':>10s} {not_found:>9,}  (recordID not in tblrecord)")
    print(f"\nIN-SCOPE TOTAL (statusID IN {IN_SCOPE_STATUS}): {in_scope_total:,} "
          f"({in_scope_total / len(report) * 100:.1f}% of {len(report):,})")

    # ---- (b) balanced in-scope sample by authoritative fileExtension ----
    buckets: dict[str, list[dict]] = defaultdict(list)
    for r in report:
        rec = joined.get(r["recordID"].upper())
        if rec is None or rec["statusID"] not in IN_SCOPE_STATUS:
            continue
        strat = stratum_of(rec.get("fileExtension"), r.get("fileSizeBytes"))
        if strat is not None:
            enriched = dict(r)
            enriched["stratum"] = strat
            enriched["_statusID"] = rec["statusID"]
            enriched["_fileExtension"] = rec.get("fileExtension")
            buckets[strat].append(enriched)

    print("\n=== in-scope population by stratum ===")
    for s in STRATA:
        print(f"  {s:13s} {len(buckets[s]):>8,}")

    rng = random.Random(SEED)
    want = allocate(args.n, list(STRATA))
    sample: list[dict] = []
    for s in STRATA:
        pool = buckets[s]
        take = min(want[s], len(pool))
        if take < want[s]:
            print(f"  ! stratum '{s}' short: wanted {want[s]}, have {len(pool)}")
        sample.extend(rng.sample(pool, take))
    rng.shuffle(sample)

    out_fields = fieldnames + ["stratum", "_statusID", "_fileExtension"]
    with args.sample_out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=out_fields)
        w.writeheader()
        w.writerows(sample)

    got = Counter(r["stratum"] for r in sample)
    print(f"\nWrote {len(sample)} in-scope rows -> {args.sample_out}")
    print("Sample by stratum:", dict(got))


if __name__ == "__main__":
    main()
