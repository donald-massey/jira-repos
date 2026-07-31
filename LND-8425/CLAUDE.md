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
- **VERDICT (corrected — Donald): Level 2 no-abstract-mapping, covered by the LND-8708 fix.** A legal on the document face (or a CSTitle tblLandDescription row) does NOT yield a mapping_id. For DIV1-sourced counties like MIAMI, the producer's land description IS the abstract mapping: div1_get_land_descriptions.sql reads `tblleaseAbstractMapping ⋈ tblAbstract` — descriptions, S/T/R and legacy_mapping_id all come from that join. No tblleaseAbstractMapping row = no land description on this path AND no mapping_id. CSTitle tblLandDescription (COLE output) is a different table the producer doesn't read for DIV1 leases → COLE reprocess is the WRONG lever. All 3 KS records = leaseID non-null (query_1) + zero tblleaseAbstractMapping (query_2/query_3), i.e. Level 2, identical to MISSAUKEE (LND-8364). Root cause: leases never abstracted in DIV1/Landtrac → mapping_id null → glue drops (correct current behavior). **Remediation = LND-8708 proposed fix (publish unmapped leases to ES cache, skip DS9); covers all 3.** No COLE reprocess, no separate abstracting ticket for LND-8425.

## Root cause (Donald, locked)
- **The IIF load failed to create the DIV1 abstract mapping.** tblleaseAbstractMapping has zero rows for LeaseID 5184347 → mapping_id null → land-aws-glue filter_records_without_mapping_id() drops it. IIF is the mechanism that creates the abstract mapping; it did not produce one for this lease.
- Land descriptions are confirmed present on the source documents (image review, all 3 records) → the data exists to be mapped; this is an IIF mapping gap, NOT a no-legal document and NOT a content gap.
- COLE query_4 result (OCRErrorMessage "No pdf could be downloaded…", 2025-09-14) is supporting detail only — NOT the root cause. Do not frame COLE as root cause.

## Remediation
- Get the IIF load to create the abstract mapping for these leases (re-export via ch-lease-exporter / re-run IIF) → tblleaseAbstractMapping.mappingid populated → mapping_id carried → land-aws-glue publishes.

## Next
- Confirm the same IIF/abstract-mapping gap for the two 2020 records (4709084, 4687944).
- Jira comment 5097544 UPDATED: root cause = IIF failed to create abstract mapping; next = get IIF to create the mapping.
- Runbook Level 1a image-read step: SKIPPED per Donald (do not edit Confluence).
- Write findings to LND-8425 in standard Jira format once query_3/query_4 return.
