"""
sample_stratified.py
====================
LND-8482 — draw a stratified 100-row sample from the full cleanup_report so the
A/B dry run exercises every repair code path, not just the majority file type.

Strata (by the s3FilePath extension + the recorded defect):
  tif       — s3FilePath ends .tif/.tiff (always needs Pillow conversion)
  pdf_zero  — .pdf with fileSizeBytes == 0 (empty PDF; recovery or hard-fail)
  pdf_null  — .pdf with fileSizeBytes > 0 (pageCount NULL only; likely metadata-only)

Equal allocation across the three strata (falls back to whatever a short stratum
has). Deterministic: fixed seed so the sample reproduces exactly.

Output: sample_100.csv — same columns as the input report plus a `stratum` column
(harmless to repair_from_report, which reads only recordID + s3FilePath). The
stratum column lets ab_compare.py bucket the before/after results.

    python query_1/sample_stratified.py \
        artifacts/cleanup_report_commit_20260713T231201Z.csv \
        --n 100 --out query_1/sample_100.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import random
from collections import defaultdict
from pathlib import Path

SEED = 8482
STRATA = ("tif", "pdf_zero", "pdf_null")


def classify(row: dict) -> str | None:
    ext = os.path.splitext(row["s3FilePath"].lower())[1]
    if ext in (".tif", ".tiff"):
        return "tif"
    if ext == ".pdf":
        try:
            size = int(row.get("fileSizeBytes") or 0)
        except ValueError:
            size = 0
        return "pdf_zero" if size == 0 else "pdf_null"
    return None  # other extension — not one of the three requested strata


def allocate(n: int, strata: list[str]) -> dict[str, int]:
    """Split n as evenly as possible across the strata (earlier strata get the remainder)."""
    base, extra = divmod(n, len(strata))
    return {s: base + (1 if i < extra else 0) for i, s in enumerate(strata)}


def main() -> None:
    ap = argparse.ArgumentParser(description="Stratified sample of a cleanup_report CSV (LND-8482).")
    ap.add_argument("report_csv", type=Path)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--out", type=Path, default=Path("query_1/sample_100.csv"))
    args = ap.parse_args()

    with args.report_csv.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fieldnames = reader.fieldnames or []
        buckets: dict[str, list[dict]] = defaultdict(list)
        for row in reader:
            k = classify(row)
            if k is not None:
                buckets[k].append(row)

    print("Population by stratum:")
    for s in STRATA:
        print(f"  {s:9s} {len(buckets[s]):>8,}")

    rng = random.Random(SEED)
    want = allocate(args.n, list(STRATA))
    sample: list[dict] = []
    for s in STRATA:
        pool = buckets[s]
        take = min(want[s], len(pool))
        if take < want[s]:
            print(f"  ! stratum '{s}' short: wanted {want[s]}, have {len(pool)}")
        chosen = rng.sample(pool, take)
        for r in chosen:
            r["stratum"] = s
        sample.extend(chosen)

    rng.shuffle(sample)  # interleave strata so progress logging isn't front-loaded by type

    args.out.parent.mkdir(parents=True, exist_ok=True)
    out_fields = list(fieldnames) + ["stratum"]
    with args.out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=out_fields)
        w.writeheader()
        w.writerows(sample)

    print(f"\nWrote {len(sample)} rows -> {args.out}")
    got = defaultdict(int)
    for r in sample:
        got[r["stratum"]] += 1
    print("Sample by stratum:", dict(got))


if __name__ == "__main__":
    main()
