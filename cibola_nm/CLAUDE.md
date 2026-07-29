# cibola_nm: Cibola (NM) missing IA Summary / tract info investigation

## Goal

Explain why Cibola (NM) courthouse documents in the CH3.0 index (`courthouse-chdplants`)
show **no IA Summary and no tract info**, and determine the fix. Investigation only — no
pipeline code changes live here; the actionable output is the root cause plus the exact
`courthouse-land-data-loader` status-file rewind needed to republish.

**Status:** Root cause confirmed. Fix is an operational reprocess (see *The fix*).

## Conclusion (one line)

It is a **`courthouse-land-data-loader` publish gap, not an OCR / IIE / scan-quality
problem.** ~3,675 of ~107k Cibola docs (≈3.4%) were OCR'd + IIE'd by COLE on **2026-06-27**,
but the loader last manufactured/published these into the live index (alias
`courthouse-chdplants_v2` → `dbpipeline-20260608`, built June 9) **before** that OCR run and
never re-published them. So in Elasticsearch `OCRs3Path = null`, which cascades to both
symptoms: no IA Summary (generated from OCR text) and no nonkeyed tract info (IIE-extracted
tract was never published — only the pre-existing KEYED tract shows). See `query_3/COMMENT.txt`.

## Data-source topology

Cibola courthouse records are **courthouseDirectTitle (CHD)**, mapped in the loader as:

| loader source (`acquire/databases.py`) | DB | s3 folder |
|---|---|---|
| `KeyedCountyDataSource` | countyScansTitle (CST) | `keyedcountydatasource` |
| `NonKeyedAndHistoricalDataSource` ← **our records** | courthouseDirectTitle (CHD) | `nonkeyedandhistoricaldatasource` |
| `EnhancedClerkDataSource` | CS_Digital (CSD) | `enhancedclerkdatasource` (OCR paths live here) |

**Critical join fact:** CHD `recordID`s do **not** exist in `CS_Digital.tblrecord` (0/500 in
testing). They link to CSD via `tblDimlXref.recordID` → `package_id` → `cole.tblRecordProcessingLogs`.
Any CSD lookup for CHD records must drive off the xref, never `tblrecord`.

**Servers (different boxes — no linked server for CHD↔CSD):**
- CST: `AUS2-DTF-PAP01V`
- CS_Digital: `aus2-ch2-petl01v.na.drillinginfo.com`

## Files

Numbered task folders, per repo convention. Each folder holds its SQL, scripts, and outputs.

### query_1/ — SQL Server diagnostic (CST + CSD side-by-side)
- `cibola-nm_query_1.sql` — two blocks joining `tblrecord` → `tblDimlXref` → `cole.tblRecordProcessingLogs` → `tblS3Image` for Cibola, one from countyScansTitle, one from CS_Digital. Shows the full COLE/OCR/S3 picture per record.
- `cibola-nm_tblRecordProcessingLogs_CSD.csv` (3,529 rows), `..._CST.csv` (3,528 rows) — outputs.

### query_2/ — COLE fixed-dataset input
- `cibola-nm_query_2.sql` — minimal projection (`recordID, countyName, stateAbbreviation, imageLocation, s3FilePath`) from CS_Digital for Cibola, formatted as COLE reprocess input.
- `cibola-nm_query_2.csv` (168 rows).

### query_3/ — CHD publish-gap tracer (the decisive work)
- `cibola-nm_courthouseDirectTitle.sql` — pulls all Cibola CHD records from `courthouseDirectTitle` joined to its own COLE/S3 tables.
- `cibola-nm_courthouseDirectTitle.csv` (104,035 rows) — the full CHD Cibola population; recordID in column 1.
- `query_cs_digital_from_chd_csv.py` — reads CHD recordIDs from that CSV, bulk-loads them into a `#chd_ids` temp table on CS_Digital (`fast_executemany`, single scan — no chunked `IN()`), LEFT JOINs `tblDimlXref` + `cole.tblRecordProcessingLogs` with `in_diml_xref`/`in_cole_logs` presence flags so records absent from DIML/COLE surface as rows, not omissions. Trusted auth. Outputs:
  - `cs_digital_match_smoke.csv` (500-row smoke test), `cs_digital_cole_check.csv` (104,035 rows).
- `es_instrument_number_query.json` — Elasticsearch DSL playbook (ES8). Existence checks, `Tractinfo`/`LandDescriptions` exists-aggs (nested-wrapped), instrument-type miss-rate breakdown, and the `OCRs3Path` present-vs-missing scope agg with `MfgUpdatedAt` date-histogram that pinned the one-batch staleness. Query against the **live** index (`dbpipeline-20260608`), not the stale `20260305` snapshot.
- `verify_ocr_publish_gap.py` — **Databricks notebook** (`# Databricks notebook source`). Traces where `OCRs3Path` drops out across import → manufacture → publish so you know how far up to rewind. Widgets: `env`, `version` (blank = read `chldl_version.json`), `county`, `state`. Reads `stage/full/records` (decisive: is `OCRs3Path` populated post-manufacture?) and the `import/.../record_ocr_s3_path` OCR caches.
- `COMMENT.txt` — the written-up finding (posted to the ticket).

## The fix — republish via the increment path

The gap is that manufacture last ran before the 2026-06-27 OCR batch. Re-running **publish
alone does nothing**: publish carries `OCRs3Path` straight from `stage/full/records`, where it
is null. You must re-drive import → manufacture → publish, and it **must run in increment
mode**, because full-mode manufacture filters by the record's own `_ModifiedDateTime`
(`data_manufacturer.py:65-68`) — an OCR-only change has an old row date and gets filtered out.

**Rewind exactly two `status.json` files, both to the same `2026-06-26T...` ISO timestamp**
(in `s3://land-manufacturing-{env}/data/courthouse-land-data-loader/{version}/`):

1. `import/full/status.json` → `last_processed_date` — makes import re-pull `_ModifiedDateTime > 06-26`, recapturing the 06-27 OCR batch into `import/increment/.../record_ocr_s3_path`.
2. `stage/full/status.json` → `last_processed_date` — this is the **manufacture** stage's status (`S3_MANUFACTURING_FOLDER = 'stage'`). It must byte-match so manufacture's chaining check passes: `import_increment_is_used = stage/full.last_processed_date == import/increment.data_newer_than` (`data_manufacturer.py:46-48`). When true, the OCR increment unions into `increment_child_records` and pulls the stale parent records; when false, you fall back into the full-mode filter that caused this.

**Do NOT hand-edit** `import/increment/status.json` (import overwrites its `data_newer_than`
on run) or `stage/increment/status.json` (manufacture writes it; not read for the mode
decision). Alternative to the surgical rewind: a **full reload** re-manufactures all records
unconditionally (no date filter), then publish.

Run order: import → manufacture → publish. Pick the 06-26 timestamp just before the earliest
06-27 OCR row to keep the increment scope small (further back = more harmless upsert churn).

## Conventions / gotchas

- CS_Digital access is Windows/**trusted auth** — no creds. `.env.example` only overrides `CSD_SERVER`/`CSD_DATABASE`; script defaults are baked in.
- `SELECT *` across the joins repeats column names (`recordID`, `_ModifiedDateTime`, `package_id`); `query_cs_digital_from_chd_csv.py` de-dupes headers with numeric suffixes so nothing is dropped. CSVs are UTF-8 with BOM (SSMS) — read with `utf-8-sig`.
- ES: query the **live alias/index**, not a stale dated snapshot; `LandDescriptions` is a **nested** field (use nested-wrapped `exists`, not a flat `exists`).
- Match schema column casing exactly (`OCRs3Path`, `fileSizeBytes`, `_ModifiedDateTime`).
