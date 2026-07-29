# CH3.0 County Investigation Template

## Purpose

Reusable starting point for CH3.0 county "missing IA Summary / tract info" investigations.
Captures the query patterns built during the Cibola (NM) investigation (LND-8721) so future
county tickets don't have to rebuild them from scratch.

Copy this folder to the relevant ticket folder, replace `{COUNTY}` / `{STATE}` placeholders,
and run in order.

## Data-source topology

CH3.0 county records can come from three sources depending on the county:

| loader source (`acquire/databases.py`) | DB | s3 folder |
|---|---|---|
| `KeyedCountyDataSource` | countyScansTitle (CST) | `keyedcountydatasource` |
| `NonKeyedAndHistoricalDataSource` | courthouseDirectTitle (CHD) | `nonkeyedandhistoricaldatasource` |
| `EnhancedClerkDataSource` | CS_Digital (CSD) | `enhancedclerkdatasource` (OCR paths live here) |

**Critical join fact:** CHD `recordID`s do **not** exist in `CS_Digital.tblrecord`.
They link to CSD via `tblDimlXref.recordID` → `package_id` → `cole.tblRecordProcessingLogs`.
Any CSD lookup for CHD records must drive off the xref, never `tblrecord`.

**Servers (different boxes — no linked server for CHD↔CSD):**
- CST: `AUS2-DTF-PAP01V`
- CSD: `aus2-ch2-petl01v.na.drillinginfo.com`
- CHD: runs on a separate server; confirm per ticket

## Files

### query_1/ — SQL Server diagnostic (CST + CSD)

`diagnostic.sql` — two SELECT blocks (CST and CSD) joining `tblrecord` → `tblDimlXref` →
`cole.tblRecordProcessingLogs` → `tblS3Image`. Shows the full COLE/OCR/S3 picture per record.
Run on `AUS2-DTF-PAP01V` (CS_Digital accessible as a linked server from there).

### query_2/ — COLE fixed-dataset input

`cole-input.sql` — minimal projection (`recordID, countyName, stateAbbreviation, imageLocation,
s3FilePath`) from CS_Digital, formatted for a COLE reprocess submission.

### query_3/ — CHD publish-gap tracer (the decisive work)

`courthouse-direct-title.sql` — pulls the target county's CHD records from
`courthouseDirectTitle`. Output CSV goes to `courthouse-direct-title.csv` in this folder —
it feeds `query_cs_digital_from_chd_csv.py`.

`query_cs_digital_from_chd_csv.py` — reads CHD recordIDs from the CSV, bulk-loads them into
a `#chd_ids` temp table on CS_Digital (trusted auth, `fast_executemany`), LEFT JOINs
`tblDimlXref` + `cole.tblRecordProcessingLogs` with `in_diml_xref`/`in_cole_logs` presence
flags. Single scan — no chunked IN() lists. Outputs `cs_digital_cole_check.csv`.

`verify_ocr_publish_gap.py` — Databricks notebook. Traces where `OCRs3Path` drops out across
import → manufacture → publish. Set the `env`, `county`, `state` widgets; `version` can be
blank (reads `chldl_version.json`). Decisive check: if `OCRs3Path` is null in
`stage/full/records`, the fix is upstream of publish.

`es_county_investigation.json` — Elasticsearch DSL playbook. Runs top-to-bottom; stop at the
first query that returns 0 hits. Covers existence checks, tract-info / LandDescriptions
gap aggs (nested-wrapped), OCRs3Path scope, MfgUpdatedAt histogram, alias/index discovery,
and instrument-type miss-rate breakdown.

## Key gotchas

- CHD recordIDs never exist in CS_Digital.tblrecord — always join via tblDimlXref.
- CHD and CSD are on different servers; `query_cs_digital_from_chd_csv.py` exists because
  there is no linked server between them.
- `SELECT *` across the joins produces duplicate column names (recordID, _ModifiedDateTime,
  package_id). The Python script de-dupes headers with numeric suffixes automatically.
- CSVs exported from SSMS are UTF-8 with BOM — read with `utf-8-sig`.
- ES: always query the **live alias** (`courthouse-chdplants_v2`), not a stale dated snapshot.
  `LandDescriptions` is a **nested** field — use nested-wrapped `exists`, not a flat `exists`.
- Match schema column casing exactly: `OCRs3Path`, `fileSizeBytes`, `_ModifiedDateTime`.
- CS_Digital access is Windows/trusted auth — no creds. `.env.example` only overrides
  `CSD_SERVER`/`CSD_DATABASE` if the defaults differ.

## Publish-gap fix pattern (from LND-8721)

If `OCRs3Path` is null in `stage/full/records` but present in the import OCR cache with a
post-manufacture date, the fix is a status-date rewind — NOT a full reload:

1. Roll `import/full/status.json` → `last_processed_date` back to just before the OCR batch.
2. Roll `stage/full/status.json` → `last_processed_date` to the **same value** so the
   manufacture chaining check passes (`data_manufacturer.py:46-48`).

Run: import → manufacture → publish (increment mode). Do NOT re-run publish alone — it
carries `OCRs3Path` straight from `stage/full/records` and null stays null.
