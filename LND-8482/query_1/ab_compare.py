"""
ab_compare.py
=============
LND-8482 — A/B the 100-file dry run: original (input report) vs after (repair
report), joined on recordID.

  A = original state: the input sample's pageCount (NULL) + fileSizeBytes (the
      defect the cleanup flagged).
  B = repaired state: the dry run's pageCount, fileSizeBytes, kind, status.

Emits ab_results.csv (one row per sampled record) and prints a per-stratum
summary: how many would repair, split by kind (tif_converted / pdf_valid /
pdf_recovered), and how many skipped/failed with the reason.

    python query_1/ab_compare.py \
        --sample query_1/sample_100.csv \
        --repair artifacts/repair_report_dryrun_<stamp>.csv \
        --out query_1/ab_results.csv
"""
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


def load(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def main() -> None:
    ap = argparse.ArgumentParser(description="A/B before-vs-after for the LND-8482 dry run.")
    ap.add_argument("--sample", type=Path, required=True)
    ap.add_argument("--repair", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("query_1/ab_results.csv"))
    args = ap.parse_args()

    sample = load(args.sample)
    repair = {r["recordID"].upper(): r for r in load(args.repair)}

    rows: list[dict] = []
    for s in sample:
        rid = s["recordID"]
        r = repair.get(rid.upper(), {})
        rows.append({
            "recordID": rid,
            "stratum": s.get("stratum", ""),
            "before_pageCount": s.get("pageCount", "") or "NULL",
            "before_fileSizeBytes": s.get("fileSizeBytes", ""),
            "after_status": r.get("status", "MISSING"),
            "after_kind": r.get("kind", ""),
            "after_pageCount": r.get("pageCount", ""),
            "after_fileSizeBytes": r.get("fileSizeBytes", ""),
            "reason": r.get("reason", ""),
        })

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    # ---- Summary ----
    by_stratum: dict[str, Counter] = defaultdict(Counter)
    kind_by_stratum: dict[str, Counter] = defaultdict(Counter)
    fail_reasons: Counter = Counter()
    for r in rows:
        by_stratum[r["stratum"]][r["after_status"]] += 1
        if r["after_status"] in ("would_repair", "repaired"):
            kind_by_stratum[r["stratum"]][r["after_kind"]] += 1
        elif r["after_status"] in ("failed", "MISSING"):
            fail_reasons[r["reason"] or r["after_status"]] += 1

    print(f"\nA/B results -> {args.out}  ({len(rows)} records)\n")
    print(f"{'stratum':10s} {'total':>5s} {'ok':>4s} {'skip':>5s} {'fail':>5s}   kinds")
    for strat in sorted(by_stratum):
        c = by_stratum[strat]
        ok = c.get("would_repair", 0) + c.get("repaired", 0)
        skip = c.get("skipped", 0)
        fail = c.get("failed", 0) + c.get("MISSING", 0)
        kinds = ", ".join(f"{k}={v}" for k, v in kind_by_stratum[strat].items())
        print(f"{strat:10s} {sum(c.values()):>5d} {ok:>4d} {skip:>5d} {fail:>5d}   {kinds}")

    if fail_reasons:
        print("\nFailure / skip reasons:")
        for reason, n in fail_reasons.most_common():
            print(f"  {n:>3d}  {reason}")


if __name__ == "__main__":
    main()
