"""LND-8451 Shape 2 check: do the two package_ids on a duplicate recordID point to the same PDF
(by CONTENT), and — when they do — which package_id should the dedupe keep?

Input  : CSV exported from Step B ("SHAPE 2 PAIRS") of identify_duplicate_xref_records.sql
         (columns: RecordID, package_id_1, package_id_2, ...context...).
Output : same CSV plus per-package PDF size/ETag, OCR/IIE artifact presence, a `verdict`,
         and (for same_pdf rows) a `keep_package_id`:
           same_pdf            -> the two root instrument_pdf objects are byte-identical
                                  (same size + same ETag, or hash-confirmed). Safe to dedupe.
                                  keep_package_id = the package with the more complete OCR+IIE
                                  artifacts (blank on a tie -> SQL falls back to latest
                                  _ModifiedDateTime).
           different_pdf       -> different bytes (different size, or same size + different MD5,
                                  or hash mismatch). Wrong-document case; resolve before deleting,
                                  add to the COLE reprocess set. keep_package_id left blank.
           same_size_unverified-> identical size but ETags couldn't decide (multipart) and the
                                  object exceeded --hash-max-mb, so bytes weren't hashed. Treat as
                                  NOT safe to dedupe (excluded from dedupe scope); review manually.
           missing_pdf         -> a package_id has no root instrument_pdf dataset.
           lookup_error        -> a DIML or S3 call failed for the row (see error column).

WHY content, not the URL: a DIML download_url is s3://<bucket>/<package_id>/<dataset_id>/<file>,
so the <package_id>/<dataset_id> segments differ for ANY two packages even when the underlying
PDF is identical. Comparing the URL/path therefore always says "different". This script instead
compares the object's S3 content fingerprint: ContentLength (size) + ETag (S3's MD5 for
single-part uploads), fetched with a 1-byte ranged GET on the presigned URL — no full download,
no AWS credentials (the presigned URL self-authorizes). For the ambiguous case (same size but
multipart ETags that can't be compared directly) it downloads and SHA-256s both, up to --hash-max-mb.

Requires the `diml_api_helper` package and DIML/OAM network access. Run it with this repo's
venv interpreter, which already has the dependency installed — `.\\.venv\\Scripts\\python.exe`
(the global `python` does not).

DIML host is hardcoded to PROD (app-a-in.drillinginfo.com/diml-core) and is NOT configurable:
dev is not reliably in sync with prod, so a verdict computed there could be wrong, and the
tblDimlXref dedupe runs against prod anyway. Only DIML_OAMUSERNAME is read from env (default
diml-svc). VPN must be up. Each row makes 2 DIML calls + up to 2 ranged GETs, so a full ~4,500-row
run is slower than the metadata-only version — use --limit to smoke-test first.

The output CSV's `verdict` and `keep_package_id` columns are the source of truth for
the dedupe: LND-8451_dedupe_xref.sql inlines the non-same_pdf recordIDs (its #exclude
list) and the same_pdf rows that have a keep_package_id (its #override list) directly
from this CSV.

Usage (PowerShell):
  .\\.venv\\Scripts\\python.exe LND-8451_diml_pdf_check.py --input shape2_pairs.csv --limit 50
  .\\.venv\\Scripts\\python.exe LND-8451_diml_pdf_check.py --input shape2_pairs.csv --output shape2_pdf_compare.csv
"""
import argparse
import csv
import hashlib
import os
import sys
import urllib.request

import dateutil.parser
from diml_api_helper import api


def normalize_pdf_url(download_url):
    """download_url -> s3://bucket/key, presigned query stripped (for display/audit only)."""
    if not download_url:
        return None
    base = download_url.split("?")[0]
    return base.replace("https://", "s3://").replace(".s3.amazonaws.com", "")


def _clean_etag(value):
    """Strip surrounding quotes and any weak-validator prefix from an ETag header."""
    if not value:
        return None
    return value.strip().lstrip("W/").strip('"')


def pdf_fingerprint(download_url, timeout=30):
    """(size, etag) for the object behind a presigned URL via a 1-byte ranged GET — no full download.

    etag is S3's MD5 for single-part uploads; a multipart ETag contains a '-' and is not a plain MD5.
    Returns (None, None) for a falsy URL. Raises on HTTP error (caller turns it into lookup_error).
    """
    if not download_url:
        return (None, None)
    req = urllib.request.Request(download_url, method="GET", headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        etag = _clean_etag(resp.headers.get("ETag"))
        content_range = resp.headers.get("Content-Range") or ""
        if "/" in content_range:                      # 'bytes 0-0/12345' -> total size
            size = int(content_range.rsplit("/", 1)[-1])
        else:                                          # range not honored; fall back to Content-Length
            cl = resp.headers.get("Content-Length")
            size = int(cl) if cl is not None else None
    return (size, etag)


def pdf_sha256(download_url, max_bytes, timeout=180):
    """Full SHA-256 of the object, or None if it exceeds max_bytes. Used only for ambiguous pairs."""
    req = urllib.request.Request(download_url)         # full GET
    h = hashlib.sha256()
    read = 0
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        cl = resp.headers.get("Content-Length")
        if cl is not None and int(cl) > max_bytes:
            return None
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            read += len(chunk)
            if read > max_bytes:
                return None
            h.update(chunk)
    return h.hexdigest()


def package_info(diml, package_id, cache):
    """One DIML call per package -> {pdf_url, pdf_identity, pdf_size, pdf_etag, has_ocr, has_iie}.

    Captures the presigned root-PDF URL plus its size+ETag fingerprint. Raises on DIML/S3 error.
    """
    if package_id in cache:
        return cache[package_id]
    datasets = diml.list_datasets(package_id=package_id)
    pdfs = [d for d in datasets if d.get("classification") == "instrument_pdf" and d.get("type") == "root"]
    if pdfs:
        latest = sorted(pdfs, key=lambda d: dateutil.parser.parse(d["updated_at"]), reverse=True)[0]
        pdf_url = latest.get("download_url")
        pdf_size, pdf_etag = pdf_fingerprint(pdf_url)
    else:
        pdf_url, pdf_size, pdf_etag = None, None, None
    has_ocr = any("combined_ocr_result" in (d.get("classification") or "") for d in datasets)
    has_iie = any((d.get("classification") or "") == "iie_result" for d in datasets)
    info = {
        "pdf_url": pdf_url,
        "pdf_identity": normalize_pdf_url(pdf_url),
        "pdf_size": pdf_size,
        "pdf_etag": pdf_etag,
        "has_ocr": has_ocr,
        "has_iie": has_iie,
    }
    cache[package_id] = info
    return info


def compare_content(info_a, info_b, hash_max_bytes):
    """Byte-identity verdict from size + ETag, hashing only the ambiguous (multipart) case."""
    sa, sb = info_a["pdf_size"], info_b["pdf_size"]
    ea, eb = info_a["pdf_etag"] or "", info_b["pdf_etag"] or ""
    if sa != sb:
        return "different_pdf"                         # different size => different bytes
    if ea and eb and ea == eb:
        return "same_pdf"                              # same size + same ETag => same bytes
    multipart = ("-" in ea) or ("-" in eb)
    if ea and eb and not multipart:
        return "different_pdf"                         # same size, different plain-MD5 => different bytes
    # ambiguous: missing ETag, or multipart ETags that can't be compared directly -> hash to be sure
    ha = pdf_sha256(info_a["pdf_url"], hash_max_bytes)
    hb = pdf_sha256(info_b["pdf_url"], hash_max_bytes)
    if ha is None or hb is None:
        return "same_size_unverified"                  # equal size but too large to hash
    return "same_pdf" if ha == hb else "different_pdf"


def _artifact_score(info):
    """IIE weighted over OCR (IIE is the downstream-valuable artifact and implies OCR ran)."""
    return (2 if info["has_iie"] else 0) + (1 if info["has_ocr"] else 0)


def choose_keep(pkg_a, info_a, pkg_b, info_b):
    """Keep the package with the more complete artifacts; '' when tied (SQL timestamp fallback)."""
    score_a, score_b = _artifact_score(info_a), _artifact_score(info_b)
    if score_a > score_b:
        return pkg_a
    if score_b > score_a:
        return pkg_b
    return ""


def classify(diml, pkg_a, pkg_b, cache, hash_max_bytes):
    """Return (verdict, info_a, info_b, keep_package_id, error)."""
    try:
        info_a = package_info(diml, pkg_a, cache)
        info_b = package_info(diml, pkg_b, cache)
    except Exception as e:  # DIML / S3 / HTTP failure — don't lose the rest of the run
        return "lookup_error", None, None, "", str(e)
    if info_a["pdf_size"] is None or info_b["pdf_size"] is None:
        return "missing_pdf", info_a, info_b, "", None
    verdict = compare_content(info_a, info_b, hash_max_bytes)
    keep = choose_keep(pkg_a, info_a, pkg_b, info_b) if verdict == "same_pdf" else ""
    return verdict, info_a, info_b, keep, None


def main():
    parser = argparse.ArgumentParser(description="LND-6796 Shape 2 same-PDF (by content) check + keep selection")
    parser.add_argument("--input", default="shape2_pairs.csv", help="CSV from the SHAPE 2 PAIRS query")
    parser.add_argument("--output", default="shape2_pdf_compare.csv", help="output CSV path")
    parser.add_argument("--hash-max-mb", type=int, default=200,
                        help="max object size (MB) to download+hash for the ambiguous multipart case (default 200)")
    parser.add_argument("--limit", type=int, default=0, help="only process the first N rows (0 = all)")
    args = parser.parse_args()
    hash_max_bytes = args.hash_max_mb * 1024 * 1024

    # PROD only — verdicts must come from prod DIML; dev is not reliably in sync,
    # so it could classify a pair wrong. Host is hardcoded so it can never fall back to dev.
    diml_host = "app-a-in.drillinginfo.com/diml-core"
    print(f"DIML host: {diml_host}  [PROD]", file=sys.stderr)
    diml = api.DimlApi(
        host=diml_host,
        oamusername=os.environ.get("DIML_OAMUSERNAME", "diml-svc"),
    )
    cache = {}
    tally = {"same_pdf": 0, "different_pdf": 0, "same_size_unverified": 0, "missing_pdf": 0, "lookup_error": 0}

    # utf-8-sig strips a leading BOM (SSMS "Save Results As CSV" writes one),
    # which would otherwise corrupt the first column header (e.g. "﻿RecordID").
    with open(args.input, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if args.limit:
        rows = rows[: args.limit]

    if not rows or "package_id_1" not in rows[0] or "package_id_2" not in rows[0]:
        sys.exit("Input must have package_id_1 and package_id_2 columns (export the SHAPE 2 PAIRS query).")
    out_fields = list(rows[0].keys()) + [
        "pdf_identity_1", "pdf_identity_2",
        "pdf_size_1", "pdf_size_2", "pdf_etag_1", "pdf_etag_2",
        "pkg1_has_ocr", "pkg1_has_iie", "pkg2_has_ocr", "pkg2_has_iie",
        "verdict", "keep_package_id", "error",
    ]
    with open(args.output, "w", newline="") as out:
        w = csv.DictWriter(out, fieldnames=out_fields)
        w.writeheader()
        for i, row in enumerate(rows, 1):
            verdict, info_a, info_b, keep, err = classify(
                diml, row["package_id_1"], row["package_id_2"], cache, hash_max_bytes)
            tally[verdict] += 1
            row.update(
                pdf_identity_1=info_a["pdf_identity"] if info_a else None,
                pdf_identity_2=info_b["pdf_identity"] if info_b else None,
                pdf_size_1=info_a["pdf_size"] if info_a else None,
                pdf_size_2=info_b["pdf_size"] if info_b else None,
                pdf_etag_1=info_a["pdf_etag"] if info_a else None,
                pdf_etag_2=info_b["pdf_etag"] if info_b else None,
                pkg1_has_ocr=info_a["has_ocr"] if info_a else None,
                pkg1_has_iie=info_a["has_iie"] if info_a else None,
                pkg2_has_ocr=info_b["has_ocr"] if info_b else None,
                pkg2_has_iie=info_b["has_iie"] if info_b else None,
                verdict=verdict, keep_package_id=keep, error=err,
            )
            w.writerow(row)
            if i % 100 == 0:
                print(f"  {i}/{len(rows)} processed", file=sys.stderr)

    print(f"Done. {len(rows)} recordIDs -> {args.output}")
    for k, v in tally.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
