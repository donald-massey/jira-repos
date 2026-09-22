"""Reconcile medium-priority IIE *results datasets* in ES against rows actually loaded
into CS_Digital.iie.instrument, to answer: "has every medium-priority dataset been
processed, and if not, what is the oldest created_at (the watermark reset date)?"

THE KEY (learned the hard way in LND-9028)
------------------------------------------
ES `dataset_id` is the id of the IIE *results file* (di-diml-gold-prod/{pkg}/{ds}/iie.json).
iie.instrument.dataset_id / .package_id are the *record-level* (source-document) ids carried
INSIDE that file (iie_loader.py downloads the file; records.py:38-40 writes each record's own
package_id/dataset_id). They are DIFFERENT id spaces -- joining ES dataset_id to
instrument.dataset_id matches nothing (100% false miss). The only correct join is:

    ES results dataset --(read S3 iie.json)--> records[*].package_id --> instrument.package_id

The loader dedups on records[0]["package_id"] (iie_loader.py:203) and commits a dataset
whole-or-not-at-all, so the FIRST record's package_id is a sufficient per-dataset coverage test.

Method (per monthly window in [START, END))
-------------------------------------------
  1. ES scroll: medium-priority results datasets (source_type=iie_results, classification=results,
     dataset_type=root, data.iie_priority=medium), created_at in window. Keep s3_bucket/s3_key/
     dataset_id/created_at.
  2. Concurrent S3 GET of each iie.json; parse; record (first_package_id, is_empty).
       - is_empty (records == []): loader returns None -> zero instrument rows is CORRECT, not a gap.
  3. Batch-check first_package_id against instrument.package_id (temp-table hash join).
  4. A non-empty dataset whose first_package_id is absent from instrument = a TRUE unprocessed
     dataset. Its created_at is a watermark-reset candidate.

Read-only. No writes to ES, S3, or the DB.

Scope note: scan starts at 2023-01-01 by convention (LND-9029). If pre-2023 coverage is needed,
reference LND-9029 and extend --start; LND-9028 full-history scan is the prior art.

Env
---
ES/S3: DIML_ES_CONFIG (config.json: HOST + AWS creds + region). DIML_ES_INDEX (index name).
DB:    CS_DIGITAL_DRIVER/SERVER/PORT/DATABASE. Windows auth default; CS_DIGITAL_UID/PWD for SQL auth.

Usage
-----
  python verify_coverage.py --start 2023-01-01 --end 2026-10-01 --out candidates_medium.csv
  python verify_coverage.py --start 2023-01-01 --end 2026-10-01 --sample 500   # quick smoke test
"""
import argparse
import csv
import datetime
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
import pyodbc


def log(msg):
    """Print immediately -- stdout is block-buffered when piped, so flush every line."""
    print(msg, flush=True)


DEFAULT_ES_CONFIG = (
    r"C:\Users\donald.massey\AppData\Local\JetBrains\PyCharm2026.1"
    r"\remote_sources\-728040595\1015593779\diml_es_index\configs\config.json"
)
DEFAULT_INDEX = "diml-denormalized-dataset-prod1"

MEDIUM_PRIORITY_MUST = [
    {"term": {"source_type": "iie_results"}},
    {"term": {"classification": "results"}},
    {"term": {"dataset_type": "root"}},
    {"term": {"data.iie_priority": "medium"}},
]
DB_IN_BATCH = 1000
S3_WORKERS = int(os.environ.get("S3_WORKERS", "48"))


def _load_cfg():
    return json.load(open(os.environ.get("DIML_ES_CONFIG", DEFAULT_ES_CONFIG)))["DEFAULT"]


def _es_client(cfg):
    from elasticsearch import Elasticsearch, RequestsHttpConnection
    from requests_aws4auth import AWS4Auth
    auth = AWS4Auth(cfg["AWS_ACCESS_KEY_ID"], cfg["AWS_SECRET_ACCESS_KEY"], cfg["AWS_REGION"], "es")
    return Elasticsearch(
        hosts=[{"host": cfg["HOST"], "port": 443}],
        http_auth=auth, use_ssl=True, verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=60, retry_on_timeout=True, max_retries=5,
    )


def _s3_client(cfg):
    return boto3.client(
        "s3", region_name=cfg.get("AWS_REGION", "us-east-1"),
        aws_access_key_id=cfg["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=cfg["AWS_SECRET_ACCESS_KEY"],
    )


def _get_conn():
    """Read-only pyodbc connection to CS_Digital. Windows auth by default."""
    parts = [
        "DRIVER={{{}}}".format(os.environ["CS_DIGITAL_DRIVER"]),
        "SERVER={},{}".format(os.environ["CS_DIGITAL_SERVER"], os.environ.get("CS_DIGITAL_PORT", "1433")),
        "DATABASE={}".format(os.environ["CS_DIGITAL_DATABASE"]),
        "Encrypt=yes", "TrustServerCertificate=yes", "Connection Timeout=30",
    ]
    uid, pwd = os.environ.get("CS_DIGITAL_UID"), os.environ.get("CS_DIGITAL_PWD")
    parts += ["UID={}".format(uid), "PWD={}".format(pwd)] if uid and pwd else ["Trusted_Connection=yes"]
    return pyodbc.connect(";".join(parts))


def _es_datasets(es, index, window_start, window_end):
    """List of {dataset_id, created_at, s3_bucket, s3_key} for medium-priority results
    datasets with created_at in [window_start, window_end). Uses the scroll API."""
    from elasticsearch import helpers
    query = {"query": {"constant_score": {"filter": {"bool": {
        "must": MEDIUM_PRIORITY_MUST,
        "filter": {"range": {"created_at": {
            "gte": window_start.isoformat(), "lt": window_end.isoformat()}}},
    }}}}}
    out = []
    for hit in helpers.scan(es, index=index, query=query, size=5000, scroll="5m",
                            _source=["dataset_id", "created_at", "s3_bucket", "s3_key"],
                            track_scores=False):
        out.append(hit["_source"])
        if len(out) % 20000 == 0:
            log(f"    ...ES scrolled {len(out):>7} datasets")
    return out


def _first_package_ids(s3, datasets):
    """Concurrent S3 GET of each dataset's iie.json. Returns
    (results, n_empty, n_error) where results = list of (dataset_id, created_at, first_pkg)."""
    results, n_empty, n_error = [], 0, 0
    done = 0

    def fetch(ds):
        obj = s3.get_object(Bucket=ds["s3_bucket"], Key=ds["s3_key"])
        recs = json.loads(obj["Body"].read())
        first = recs[0].get("package_id") if recs else None
        return ds, first, len(recs)

    with ThreadPoolExecutor(max_workers=S3_WORKERS) as ex:
        futs = {ex.submit(fetch, ds): ds for ds in datasets}
        for fut in as_completed(futs):
            done += 1
            try:
                ds, first, nrec = fut.result()
                if nrec == 0:
                    n_empty += 1
                elif first:
                    results.append((ds["dataset_id"], ds.get("created_at"), first))
            except Exception as e:
                n_error += 1
                if n_error <= 5:
                    log(f"    S3 error on {futs[fut].get('s3_key')}: {type(e).__name__}: {e}")
            if done % 20000 == 0:
                log(f"    ...S3 fetched {done}/{len(datasets)}")
    return results, n_empty, n_error


def _present_package_ids(package_ids):
    """Subset of package_ids present in iie.instrument, via one temp-table hash join.

    Opens a FRESH connection each call: the long S3 fetch that precedes it would leave
    a persistent connection idle long enough for the server to drop it (10054)."""
    ids = list(package_ids)
    conn = _get_conn()
    try:
        cur = conn.cursor()
        cur.execute("CREATE TABLE #pkg (package_id VARCHAR(64) PRIMARY KEY);")
        cur.fast_executemany = True
        t = time.time()
        for i in range(0, len(ids), DB_IN_BATCH):
            cur.executemany("INSERT INTO #pkg (package_id) VALUES (?)",
                            [(x,) for x in ids[i:i + DB_IN_BATCH]])
        cur.execute("SELECT c.package_id FROM #pkg c "
                    "WHERE EXISTS (SELECT 1 FROM iie.instrument i WHERE i.package_id = c.package_id);")
        present = {row[0] for row in cur.fetchall()}
        log(f"    DB join: {len(ids)} package_ids -> {len(present)} present ({time.time()-t:.1f}s)")
        return present
    finally:
        conn.close()


def _month_windows(start, end):
    cur = datetime.datetime(start.year, start.month, 1)
    while cur < end:
        nxt = datetime.datetime(cur.year + 1, 1, 1) if cur.month == 12 \
            else datetime.datetime(cur.year, cur.month + 1, 1)
        yield max(cur, start), min(nxt, end)
        cur = nxt


def run(start, end, out_path, sample):
    cfg = _load_cfg()
    log("Connecting ES / S3 / DB...")
    es = _es_client(cfg)
    s3 = _s3_client(cfg)
    index = os.environ.get("DIML_ES_INDEX", DEFAULT_INDEX)
    _get_conn().close()  # fail fast if DB creds/host are wrong
    log(f"Connected. Reconciling {start:%Y-%m-%d} -> {end:%Y-%m-%d} by month"
        f"{' (sample %d/mo)' % sample if sample else ''}.\n")

    tot_es = tot_empty = tot_err = tot_checked = tot_missing = 0
    candidates = []
    for w_start, w_end in _month_windows(start, end):
        month = w_start.strftime("%Y-%m")
        log(f"[{month}] ES enumerate...")
        datasets = _es_datasets(es, index, w_start, w_end)
        if not datasets:
            log(f"[{month}] ES=0\n")
            continue
        if sample:
            datasets = datasets[:sample]
        log(f"[{month}] ES={len(datasets)}; S3 fetch first package_id...")
        triples, n_empty, n_err = _first_package_ids(s3, datasets)
        pkg_to_rows = {}
        for did, cat, pkg in triples:
            pkg_to_rows.setdefault(pkg, []).append((did, cat))
        present = _present_package_ids(pkg_to_rows.keys()) if pkg_to_rows else set()
        missing = [(did, cat, month, pkg)
                   for pkg, rows in pkg_to_rows.items() if pkg not in present
                   for (did, cat) in rows]
        tot_es += len(datasets); tot_empty += n_empty; tot_err += n_err
        tot_checked += len(pkg_to_rows); tot_missing += len(missing)
        candidates.extend(missing)
        flag = "  <-- UNPROCESSED" if missing else ""
        log(f"[{month}] ES={len(datasets):>7}  empty={n_empty:>6}  errors={n_err:>4}  "
            f"checked_pkgs={len(pkg_to_rows):>7}  missing={len(missing):>6}{flag}\n")

    log(f"TOTAL  ES={tot_es}  empty={tot_empty}  s3_errors={tot_err}  "
        f"distinct_pkgs_checked={tot_checked}  unprocessed={tot_missing}")
    if tot_missing:
        candidates.sort(key=lambda r: (r[1] or ""))
        with open(out_path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["dataset_id", "created_at", "month", "first_package_id"])
            w.writerows(candidates)
        oldest = candidates[0][1]
        log(f"Wrote {tot_missing} unprocessed datasets -> {out_path}")
        log(f"OLDEST unprocessed created_at = {oldest}")
        log(f"  -> reset iie_diml_loader-medium watermark to just BEFORE {oldest} to drain them.")
    else:
        log("No unprocessed datasets. Every non-empty medium-priority results dataset in the "
            "window has its records loaded (package_id present in iie.instrument).")
    return tot_missing


def _parse_date(s):
    return datetime.datetime.strptime(s, "%Y-%m-%d")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--start", type=_parse_date, required=True, help="inclusive, YYYY-MM-DD")
    ap.add_argument("--end", type=_parse_date, required=True, help="exclusive, YYYY-MM-DD")
    ap.add_argument("--out", default="candidates_medium.csv", help="unprocessed-dataset output CSV")
    ap.add_argument("--sample", type=int, default=0, help="cap datasets/month (smoke test)")
    args = ap.parse_args()
    sys.exit(1 if run(args.start, args.end, args.out, args.sample) else 0)


if __name__ == "__main__":
    main()
