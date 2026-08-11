# LND-8425: Recent KS LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8425
**Status:** CANDIDATE FOR DEV

Max Lease Date search for MIAMI, KS county showed that the max lease date is behind our most recent published leases.

- RecordNumber: 2025-03537
- File date: 2025-08-29
- RecordID: 68125b82-1ae2-4058-a46f-f3e46709e47b
- Div1_LeaseID: 5184347

## Approach

Apply the **LND-8426 "Missing Legal Leases — Investigation Runbook"** to the KS record.
Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284
LND-8425 is an "action item from" LND-8426; this is the repeat-for-KS execution.

**Target record:** MIAMI, KS | RecordNumber 2025-03537 | File date 2025-08-29 |
RecordID `68125b82-1ae2-4058-a46f-f3e46709e47b` | Div1_LeaseID 5184347.

### Level 1 — ch-lease-exporter / IIF Lease Importer (start here)
- Query `countyScansTitle.dbo.tblexportLog` for recordID `68125b82-...`.
  - `leaseID` is expected NON-NULL (record already shows Div1_LeaseID 5184347) → likely passes Level 1, go to Level 2.
  - If NULL → IIF never created the DIV1 row / natural-key match failed; check IIF logs
    `\\prod-loader05.prod.aus\logs\loaders\iif\iifLegalLeaseLoader.log.YYYY-WW`, quantify batch impact by zipName, document remediation (DELETE tblexportLog rows after verifying statusID IN (4,16)) — do NOT execute; hand to user.

### Level 2 — land-lease-producer -> land-aws-glue
- Source-data checks against PROD (DIV1 = V02PDIPRODDIV01.PROD.AUS; CSTitle = countyScansTitle),
  substituting KS StateID + LeaseID 5184347 / RecordID `68125b82-...`:
  - DIV1 `tblleaseAbstractMapping` (+ `tblAbstract`) — ANY abstract mapping? (mapping_id source)
  - CSTitle `tblLandDescription` (base) — KS uses the BASE path, not OH/WV/PA additional-fields.
  - (Skip PA `TblAddsFields` parcel path — not applicable to KS.)
- Interpret: no land descriptions anywhere → upstream courthouse legal-extraction gap (pipeline correct).
  Land descriptions present but no mapping_id → chase the abstract mapping.

### Scale check
- Run the mapping-split SQL (drop rate by state / MIAMI county) to confirm singleton vs pattern.
  KS was <1% in the LND-8426 table — expect a per-record miss like COLUMBIA, PA (4696618).

### Decisions (locked in planning)
- **Scope:** record trace + MIAMI county sizing + full KS/state drop-rate split (mirror PA).
- **Remediation:** document-only. If a Level-1 IIF batch race turns up, describe the unlock
  in prose; Donald runs any DELETE manually. No DELETE statements written to .sql files.

### Deliverables
- SQL + result files under `jira-repos/LND-8425/` mirroring the LND-8426 layout.
- Findings written to the ticket in the standard Jira format; update the shared runbook if KS surfaces a new failure mode.

## Files

```
query_1/LND-8425-level1-exportlog.sql        ← Level 1: tblexportLog leaseID status + batch blast-radius
query_2/LND-8425-level2-source-data.sql      ← Level 2: DIV1 abstract mapping + CSTitle base land descriptions (KS StateID)
query_3/LND-8425-mapping-split.sql           ← scale: state drop-rate split + MIAMI/KS county sizing
query_4/LND-8425-cole-processing-check.sql   ← recoverability (deep fallback): COLE OCR/IIE status for the image
query_5/LND-8425-image-storage-path.sql      ← recoverability (PREFERRED): on-prem storageFilePath → read the PDF directly
query_6/LND-8425-cole-fixed-dataset-input.sql ← DIAGNOSTIC ONLY: emit COLE fixed-dataset CSV rows (tests if COLE can OCR the images; NOT the lease fix — COLE never writes tblLandDescription)
query_6/miami-ks_<UTC>Z.csv                   ← fixed-dataset input, named {county}-{state}_{YYYYMMDDThhmmss}Z.csv (e.g. miami-ks_20260810T145410Z.csv); upload to hardcoded_input/
query_6/README.md                             ← how to run the COLE fixed-dataset flow (diagnostic; bucket, flow, computation type)
query_7/LND-8425-reexport-duplicate-check.sql ← proves organic re-export re-matches the existing lease (no duplicate) from tblexportLog history
```

Recoverability approach: **query_5 (read the image) supersedes query_4 (COLE log)** — no AWS creds, direct PDF read tells us legal-present (reprocess) vs no-legal (write-off). query_4 kept as fallback for stale-COLE cases. Mirrors _lease-investigation-template query_1/doc_image_paths.sql (Level 1a).

All scripts fully qualified ([countyScansTitle]/[div1_Daily]/[CS_Digital]); DIV1 via [LinktoDiv1Repl].

## Completed

- Planning session (grill-with-docs) — deliverable = apply LND-8426 runbook to KS record; scope + remediation decisions locked.
- KS-adapted SQL scripts written (read-only; no DELETE in files).
- **query_1 (Level 1) — PASS.** tblexportLog.leaseID = 5184347 (non-null); statusID 4, recordIsLease 1 → in producer candidate universe. Exported 2025-09-22, zip CH_09.22.2025.14.26_leases. (Batch side-note: that zip had 11 null-lease rows / 443; our record not among them.)
- **query_2 (Level 2) — root cause found.** KS StateID 20 (base path). DIV1 tblleaseAbstractMapping (LeaseID 5184347) EMPTY; CSTitle tblLandDescription (recordID) EMPTY. Record shell exists (statusID 4). → **Upstream courthouse legal-extraction gap**; mapping_id NULL so land-aws-glue correctly drops it. Not a pipeline bug. Same landing as COLUMBIA, PA (4696618).
- **query_3 (scale) — KS healthy, per-record miss confirmed.** KS drop rate 0.40% (71/17,971), near the bottom; high-drop states OH 16.04% / TX 11.92% / WV 9.51% (matches LND-8426). MIAMI county: 3 unmapped of 33 — the target (5184347/2025-03537) plus two 2020 records (4709084, 4687944). Three individual gaps over 5 years, not a backlog.
- **query_5 (image read) — confirms legitimate leases, NOT write-offs.** Read all 3 MIAMI PDFs off the on-prem share. ALL THREE carry a real legal description with S/T/R:
  - 68125b82 / 2025-03537 (OGLAMD): E½SW¼ + N½W½SW¼, Sec 5, T17S, R22E (aliquot, EXCEPT clause).
  - 912d5ae6 / 2020-04048 (OGL): metes-and-bounds in NW¼ Sec 9, T17S, R22E.
  - a36bcf38 / 2020-00921 (OGL): metes-and-bounds in SE¼ Sec 23, T18S, R21E, 6th P.M.
  Rules out COLUMBIA-PA-style document-type limitation (same role the tblLandDescription check played for ALPENA/ALCONA in LND-8364). These SHOULD publish.
- **VERDICT — root cause/remediation refined below; its "COLE reprocess is the WRONG lever" conclusion was CORRECT** (COLE never writes tblLandDescription — proven in root cause). The bullet's *reasoning* (producer reads DIV1 not CSTitle) was imprecise, but the conclusion holds. Kept for history. Original text: A legal on the document face (or a CSTitle tblLandDescription row) does NOT yield a mapping_id. For DIV1-sourced counties like MIAMI, the producer's land description IS the abstract mapping: div1_get_land_descriptions.sql reads `tblleaseAbstractMapping ⋈ tblAbstract` — descriptions, S/T/R and legacy_mapping_id all come from that join. No tblleaseAbstractMapping row = no land description on this path AND no mapping_id. CSTitle tblLandDescription (COLE output) is a different table the producer doesn't read for DIV1 leases → COLE reprocess is the WRONG lever. All 3 KS records = leaseID non-null (query_1) + zero tblleaseAbstractMapping (query_2/query_3), i.e. Level 2, identical to MISSAUKEE (LND-8364). Root cause: leases never abstracted in DIV1/Landtrac → mapping_id null → glue drops (correct current behavior). **Remediation = LND-8708 proposed fix (publish unmapped leases to ES cache, skip DS9); covers all 3.** No COLE reprocess, no separate abstracting ticket for LND-8425.

- **IIF log trace (all 3 records) + ch-lease-exporter code review — code-grounded root cause.** Confirmed the DIL land descriptions come from CSTitle `tbllandDescription` (get_records LEFT JOIN), not DIV1; DIV1 is only the leaseID match-back (match_new_leases → tblLegalLease). All 3 MIAMI leases show a bare IIF insert with no `Adding mapping for TRS` line. Re-run/re-export as-is proven to be a no-op. See root cause + remediation below.

## Root cause (code-grounded, locked)
- **The legal was never extracted into CSTitle `tblLandDescription`, so the export carried no legal and IIF had nothing to map.** Chain proven end to end:
  - IIF logs (`\\prod-loader05.prod.aus\logs\loaders\iif\`): all 3 MIAMI leases show a bare `Inserted lease` line (NA/NA or 0000/0000 vol/page) and **zero** `Adding mapping for TRS` lines. 5184347 in log `2025-39` (22:08:48), 4709084 in `2020-34`, 4687944 in `2020-18`. No IIF error — IIF received a lease with no land description and correctly created no mapping. There is no "IIF failure."
  - ch-lease-exporter `queries.py get_records()` builds the DIL from **CSTitle**: `LEFT OUTER JOIN countyScansTitle.dbo.tbllandDescription land ON land.recordID = rec.recordId` and selects `land.Section/Township/RangeOrBlock/AbstractName/Survey/...`. The **only** DIV1 touch is `match_new_leases()`, which reads `div1_daily.dbo.tblLegalLease` afterward purely to pair the new LeaseID back to the recordID and write `tblexportLog`. DIV1 is the leaseID match, NOT the land-description source.
  - query_2 showed CSTitle `tblLandDescription` is EMPTY for these recordIDs → the LEFT JOIN yielded NULL land fields → the DIL carried no legal → IIF made no `tblleaseAbstractMapping` row → `mapping_id` null → land-aws-glue `filter_records_without_mapping_id()` drops it.
- Direction of the pipeline: CSTitle `tblLandDescription` → DIL → IIF writes `div1_daily.tblleaseAbstractMapping`. IIF *stores* into DIV1, but it stores what the DIL carried.
- The legal IS on the document face (image review, all 3 records) — it was just never entered into structured `tblLandDescription` rows. Unifying gap = **CSTitle tblLandDescription empty**.
- **COLE does NOT populate this table — its output never supplements a lease (code-proven).** COLE's only DB write is `CS_Digital.cole.tblRecordProcessingLogs` (`package_id`, `errorMessage`, `OCRs3Path`) — `chunk_results_database_writer.py:79-82` → `upsert_processing_logs` → `databases.py:114-115` (`cole.tblRecordProcessingLogsUpsertStage`). Grep of the whole COLE repo for `countyScansTitle`/`tbllandDescription` writes = nothing. COLE's extracted legals live on S3 (`OCRs3Path`) and feed **courthouse-land-data-loader → the CHD courthouse ES plants** (deed/document product), NOT the lease path. `countyScansTitle.dbo.tblLandDescription` is populated by **title analysts manually abstracting the lease**. So the COLE query_4 error is a red herring for the lease; COLE reprocess cannot fix it.
- The original "COLE reprocess is the WRONG lever" verdict was RIGHT (for a cleaner reason than first stated). The two-turn detour that said "COLE IS the upstream lever" is wrong — see the writer code above.

## Remediation — manual abstracting (COLE cannot do this)
The only lever that puts a land description into the lease path is a **title analyst manually abstracting the lease**. COLE is NOT a lever (it never writes `tblLandDescription`; see root cause). Two-part fix:
1. **Manually abstract the 3 leases** — enter the section/township/range legal (confirmed present on the images) so a row lands in `countyScansTitle.dbo.tblLandDescription` (or is abstracted directly in Landtrac/DIV1 to create `tblleaseAbstractMapping`).
2. **Re-run through the export** so IIF creates the mapping: remove the existing `tblexportLog` rows for the 3 recordIDs so ch-lease-exporter re-selects them (`get_records()` filters `recordID NOT IN (SELECT recordID FROM tblexportLog)`), then the daily export DIL carries `T:17S R:22E S:5` etc. → IIF logs `Adding mapping for TRS` → `tblleaseAbstractMapping.mappingid` populated → `mapping_id` carried → land-aws-glue publishes.
- Duplicate-lease risk on step 2 — **RESOLVED, no duplicate** (query_7, tblexportLog history). Organic re-export re-matches the existing lease on the natural key; it does not mint a new LeaseID. Decisive evidence (step 6): **105,728 records were exported across 2+ distinct organic CH zips, and 100.00% kept the identical LeaseID set across every export — zero introduced a new LeaseID on re-export.** (The apparent "duplicates" in steps 1-2/5 were manual migration/legacy bulk jobs — LND-6732(2), LND-5774, LEGACY* — reassigning LeaseIDs OUTSIDE the exporter→IIF path, plus one-record-to-many-leases within a SINGLE export via MultipleLeasesForTract.) So delete-tblexportLog + re-export is safe.
- Remaining verify-after (not a blocker): confirm IIF, on re-matching the existing lease, also creates the abstract mapping from the now-populated land description. Re-run query_2 after re-export — `tblleaseAbstractMapping` should now have a row for 5184347. If it doesn't, fall back to creating the mapping directly.
- Document-only per the ticket decision: any tblexportLog DELETE is described in prose; Donald runs it after verifying statusID IN (4,16). No DELETE in .sql files.
- Note: LND-8708 (publish unmapped leases to ES cache, skip DS9) would cover all 3 without abstracting — but only in ES, and it's blocked by the DS9 georendering geometry dependency for the website map. Abstracting is the full fix.

## Next
- **Send the 3 records back for re-keying by the keyers** (= manual abstracting; the actual fix) — legals confirmed on the images.
  - Owner: **Daniel Garza** (keying team). OOO until **2026-08-11**; Donald to reach out then to flag the missing land descriptions on these 3 recordIDs.
  - Card is effectively **blocked on re-keying** until Daniel picks it up.
- Decide step-2 mechanism after re-keying: direct `tblleaseAbstractMapping` creation against existing LeaseIDs vs. clear-tblexportLog re-export (resolve the duplicate-lease risk first).
- query_6 is now **diagnostic-only**: a COLE fixed-dataset run tells you whether COLE can OCR a legal off these images (S3 output), NOT whether the lease gets a land description. It does not fix the lease. Keep for reference; not on the remediation path.
- Jira comment 5097544: re-pointed to manual abstracting (done).
- Runbook Level 1a image-read step: SKIPPED per Donald (do not edit Confluence).
