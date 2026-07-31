# LND-8426: Recent PA LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8426
**Linked cards:** https://enverus.atlassian.net/browse/LND-8424, https://enverus.atlassian.net/browse/LND-8425
**Status:** Done
**Runbook:** https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284/Missing+Legal+Leases+Investigation+Runbook+LND-8426

PA legal leases not appearing on the website. Two test records investigated:

- **COLUMBIA, PA** — RecordID `a688f5be-8530-4647-b73d-089c185c8262`, Div1 LeaseID `4696618`, RecordNumber 20190699, file date 2019-09-09
- **JEFFERSON, PA** — RecordID `46e238a6-4e63-4f1e-95bf-916083355f24`, RecordNumber 2023-004291, file date 2023-12-18

## Investigation Framework (two levels)

### Level 1 — ch-lease-exporter / IIF Lease Importer

Check `countyScansTitle.dbo.tblexportLog` for `leaseID` status. A NULL leaseID means IIF never matched the record — usually a timing race: zip arrived during IIF's 08:00–22:00 CST business-hours sleep and was cleaned up before the 22:00 wake-up run. The record is permanently excluded from future ch-lease-exporter re-exports because it matches on `leaseID`.

Remediation: `DELETE FROM countyScansTitle.dbo.tblexportLog WHERE zipName = '<zip_name>'` (verify `statusID IN (4,16)` on `tblRecord` first) to unlock all affected records for re-export.

### Level 2 — land-lease-producer → land-aws-glue

After confirming a valid leaseID exists, check whether the record has land descriptions / an abstract mapping in DIV1 (`tblleaseAbstractMapping`). Records with no `mapping_id` are correctly filtered by `filter_records_without_mapping_id()` in the glue `ElasticSearch6Cache` — this is not a pipeline bug; it is an upstream courthouse legal-description extraction gap.

## Finding: COLUMBIA, PA — 4696618 (document-type limitation)

The record reaches Kafka but carries **no land descriptions**, so it has no `mapping_id`, and the land-aws-glue `legal_lease` ES writer drops it by design (`filter_records_without_mapping_id`). Not a pipeline bug — the gap is upstream.

**COLE confirmed clean, document is the problem:**
- `tblDimlXref` maps the recordID to `package_id` c469jr2lpbg0009mdlq0.
- `cole.tblRecordProcessingLogs` has a row with `OCRErrorMessage` and `IIEErrorMessage` both NULL, OCR/IIE completed **2025-03-19** — neither a queue miss nor a failed run.
- The staged PDF was later **overwritten 2026-06-17** (455 days post-COLE) by `cs_updates`. `tblS3Image._ModifiedDateTime` and S3 `head-object LastModified` match to the millisecond.
- The current document is a **Memorandum of Coal Mining Lease** (Pagnotti Enterprises Inc → Blaschak Coal Corp). The demised premises is defined only as "approximately 834 acres in Conyngham Township, Columbia County and Mount Carmel Township, Northumberland County" shown on a map (Exhibit A). No metes-and-bounds, no section/range, no parseable textual legal anywhere. A COLE reprocess cannot manufacture a legal the document does not contain.

**Synthetic `legacy_mapping_id` fallback ruled out:** Both `tblLandDescription` and `TblAddsFields` return zero rows for 4696618 in CSTitle — no `LandDescriptionId` or parcel value exists to promote into a synthetic mapping. Document-type limitation; no recoverable fix path.

## Finding: JEFFERSON, PA — 46e238a6 (IIF timing race)

ch-lease-exporter exported the DIL on **2024-02-14** (zip `CH_02.14.2024.08.41_leases`, exportDate 2024-02-14 08:02:54) but `div1_daily.dbo.tblLegalLease` has no row for RecordNumber 2023-004291 — IIF Lease Importer never created the DIV1 entry.

**Root cause — IIF timing race:** IIF entered its business-hours sleep at 13:01 UTC (08:01 CST); the zip arrived ~14:41 UTC (08:41 CST); by the 22:00 UTC wake-up only later zips were present — the 08:41 zip was cleaned up before IIF ran.

With no DIV1 row, ch-lease-exporter wrote `leaseID = NULL` to `tblexportLog`, permanently excluding the record from future runs. Volume and page are both NULL on the CSTitle record, so the vol/page fallback also fails — a successful IIF import is required first.

IIF logs at `\\prod-loader05.prod.aus\logs\loaders\iif\iifLegalLeaseLoader.log.2024-07` confirm `CH_02.14.2024.08.41_leases` was never processed.

**Batch impact:** 428 records in `CH_02.14.2024.08.41_leases` all have `leaseID = NULL` — entire batch permanently excluded. Remediation: `DELETE FROM countyScansTitle.dbo.tblexportLog WHERE zipName = 'CH_02.14.2024.08.41_leases'` (verify `statusID IN (4,16)` first) to unlock all 428 for re-export.

## Per-state drop-rate analysis

Marcellus (PA) hypothesis **refuted**. High-drop states are OH (16%) and TX (12%). PA is 1.15% — one of the best-mapped states. Lease 4696618 is a near-singleton: only 4 candidate leases in COLUMBIA, 2 unmapped.

| State | Candidate leases | Has mapping_id | No mapping_id (dropped) | % dropped |
|-------|-----------------|----------------|------------------------|-----------|
| OH    | 100,352         | 84,211         | 16,141                 | 16.08%    |
| TX    | 521,990         | 459,783        | 62,207                 | 11.92%    |
| WV    | 184,709         | 167,093        | 17,616                 | 9.54%     |
| LA    | 60,319          | 57,234         | 3,085                  | 5.11%     |
| NM    | 36,468          | 34,667         | 1,801                  | 4.94%     |
| CO    | 34,460          | 34,018         | 442                    | 1.28%     |
| PA    | 78,833          | 77,929         | 904                    | 1.15%     |
| ND    | 60,200          | 59,808         | 392                    | 0.65%     |
| OK    | 199,396         | 198,739        | 657                    | 0.33%     |

OH and PA use the same additional-fields (parcel-number) mapping path, yet OH drops 16% vs PA 1% — something OH-specific (parcel/colonial-location match quality) drives OH's rate. Worth its own coverage ticket (relevant to LND-8424/LND-8425).

## Files

```
query_1/LND-8426.sql                              ← initial record checks
query_1/records.csv                               ← query_1 output
query_2/LND-8426-mapping-split.sql                ← per-state drop-rate analysis
query_2/load_mapped_leases.sql                    ← loads DIV1 mapped leaseIDs
query_2/div1_leaseids.csv
query_2/mapped_vs_unmapped_byState.csv
query_2/mapped_vs_unmapped_Marcellus.csv
query_2/columbia_pa_mapped_vs_unmapped.csv
query_2/tblLeaseAbstractMapping_OverTime.csv
query_2/tblLeaseAbstractMapping_OverTime_Marcellus.csv
query_3/ch_lease_exporter_match_investigation.sql
query_4/LND-8426-cole-processing-check.sql        ← COLE processing history for 4696618
LND-8426-local-dev-handoff.md                     ← end-to-end local repro instructions
local-glue-instructions.md                        ← land-aws-glue local Docker setup
LND-8426-cole-processing-check.sql               ← loose copy; canonical version in query_4/
```

## Completed

- Confirmed drop point: Glue `filter_records_without_mapping_id` gate
- Per-state drop-rate analysis — refuted Marcellus hypothesis (PA 1.15%, OH 16%, TX 12%)
- COLE follow-up for 4696618 — ran cleanly 2025-03-19; image later overwritten; document-type limitation (coal-lease Memorandum, map-only boundary)
- Synthetic `legacy_mapping_id` fallback ruled out — tblLandDescription and TblAddsFields both empty in CSTitle
- JEFFERSON 46e238a6 root cause — IIF timing race; batch of 428 records permanently excluded from ch-lease-exporter
- End-to-end local repro (land-lease-producer + land-aws-glue) documented
- Investigation runbook published to Confluence and validated
- Richard Kline reviewed findings; Aabeer Kalim identified as next owner for LND-8424/LND-8425 follow-up
