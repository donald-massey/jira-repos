# Investigation — why 131 backfilled records didn't appear downstream

Follow-up to the LND-8093 backfill: 131 records written to `tblS3Image`
(`_ModifiedBy='LND-8093'`) were checked against the two downstream caches. The
backfill itself is fine; absences trace to each consumer's own selection rules.

## Shared inputs (this folder)
- `records_to_investigate.sql` / `.csv` — the 131 records under investigation.

## legal_lease/ — land-lease-producer (Kafka → `legal_lease` ES index)
Lease-centric: a record publishes only if tied to a Div1 `category = 2` lease.
- `diagnose_not_published.*` — replays the CSTitle selection gates.
- `diagnose_div1_side.*` — Div1 instrument category check (the discriminator).
- `diagnose_group3_counties.*` — county coverage + per-county watermarks.
- `group3_26_leaseids.csv` — the 26 eligible category-2 leases (authoritative map).
- `diagnose_missing9_landdesc.sql` — land-description check for the 9 that stayed missing.
- `check_legal_lease_index.txt` — Kibana queries against `legal_lease`.

**Result:** 102 St. Landry SMEM/SOP have Div1 `instrument = -1` (not leases) → correctly
excluded; 3 have no `tblexportLog.leaseId`; 26 are eligible, 17 published, 9 missing.

## chldl/ — courthouse-land-data-loader (Spark → `courthouse-*plants` ES indices)
NOT lease-gated. A record reaches the index for plant type X only if BOTH:
1. its `source` matches X's rule (`record_transforms.filter_records_by_product`):
   abstractplants→`keyed`; chdplants→`nonkeyed` OR `keyed`+GathererID∈[12,15,20];
   enhancedclerks→`enhancedclerk`; historicalplants→`keyed`+old/county 64.
2. its county carries X's `SourceId` in the countyparish master
   (2=abstract, 4=enhancedclerk, 8=chd), matched by
   `lower(CountyParishSourceName)==lower(CountyName)` + state abbrev (LEFT join — no match
   ⇒ `CountyParishInfo` null ⇒ dropped from EVERY index).

ES `_id` == recordID (`es.mapping.id="RecordId"`); `ImageLocation` = `s3FilePath.lower()`
from the backfill, so a propagated record shows the `enverus-courthouse-prod-chd-plants` path.

Files:
- `check_chldl_abstractplants_index.txt` — Kibana sweep of all `courthouse-*` indices.
- `query_chldl_es.py` — same sweep via the ES REST endpoint (reads `.env`, writes `chldl_es_results.csv`).
- `diagnose_county_parish_delta.py` — **authoritative** county→SourceId check. Reads the
  imported `county_parish_ids` Delta table from S3 in Databricks (the exact data the pipeline
  joins). Run this one.
- `diagnose_chldl_county_parish.sql` — **wrong source, kept for the record.** Pointed at
  `CS_Stage_Prod.dbo.Vw_County`, which is EOG-keying-scoped (only `EOG_McMullen`, SourceId 2),
  not the countyparish master.
- `CHLDL_FINDINGS.md` — ticket-ready summary of the conclusion below.

**Result — all 131 accounted for (verified against prod `county_parish_ids` v20260608075104):**
- **13 present**, backfill propagated: 12 McMullen → enhancedclerks (SourceId 4),
  1 Guadalupe → chdplants (SourceId 8); all carry the `chd-plants` `ImageLocation`.
- **111 absent — county not in CHLDL scope** (no countyparish row → dropped everywhere):
  St. Landry LA (105), Cavalier ND (2), Decatur KS (1), Greeley KS (1), Morgan UT (1),
  Washington PA (1).
- **7 absent — McMullen, wrong source for its only designation.** McMullen carries SourceId 4
  (enhancedclerk) ONLY. The 12 present are `source='enhancedclerk'`; the 7 absent are plain
  `keyed` (GathererID 12) — they'd fit chdplants' source rule but McMullen has no SourceId 8,
  and they aren't enhancedclerk source, so no (source × SourceId) pair matches.

0 of 131 in abstractplants (none of these counties are abstract-plant). Nothing here is a
backfill failure — every record CHLDL actually ingests received its LND-8093 image.
Related to the legal_lease "wrong category" finding but a distinct filter: source ×
county-designation, not Div1 instrument category.
