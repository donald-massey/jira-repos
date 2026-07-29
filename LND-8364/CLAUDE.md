# LND-8364: Recent MI LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8364
**Status:** In Progress

Max Lease Date search for some MI counties showed max lease dates behind our most recent published leases.

**ALCONA, MI**

- recNum 202300002307
- 2023-08-07
- recordID cd130801-8bad-48c3-bce2-81336b1f2e14

**ALPENA, MI**

- 2022-10-28
- recordID 2f27f271-3a42-4329-813c-ba15bdc4b1b5

**MISSAUKEE, MI**

- 2026-00050
- 2026-01-08
- recordID 9504fdef-c20b-42f8-9cce-09a3991e9223

## Approach

Goal: verify the proposed fix (publish leases with no DIV1 abstract mapping to ES cache, skip DS9) covers all MI records reported by LDI.

Two known root causes from LND-8426 (PA analog):

**Level 1 — NULL leaseID in tblexportLog**
ch-lease-exporter exported the record but IIF Lease Importer never created a DIV1 entry (usually a timing race: zip arrived during IIF's 08:00–22:00 CST sleep window and was cleaned up before the 22:00 run). leaseID = NULL in tblexportLog → land-lease-producer INNER JOIN excludes the record entirely. The proposed fix does NOT cover this case.

**Level 2 — No abstract mapping in DIV1**
leaseID is non-null but tblleaseAbstractMapping has no row for it. land-aws-glue's filter_records_without_mapping_id() drops these at ES write time. The proposed fix targets exactly this case.

### Investigation sequence (query_1/)

1. `mi-exportlog-check.sql` — confirm each recordID exists in tblexportLog and whether leaseID is non-null (Level 1 gate)
2. `mi-div1-mapping-check.sql` — for records with a leaseID, check tblleaseAbstractMapping (Level 2 gate); fill in leaseIDs from step 1 results
3. `mi-land-descriptions-check.sql` — check tblLandDescription and TblAddsFields in CSTitle; zero rows means a document-type limitation (same as COLUMBIA, PA coal lease)
4. `mi-drop-rate.sql` — MI county-level drop rate to quantify the broader scope beyond the three reported records

All queries run against countyScansTitle. Steps 2 and 4 use the LinktoDiv1Repl linked server via OPENQUERY.

Reference runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284/Missing+Legal+Leases+Investigation+Runbook+LND-8426

## Completed

<!-- Updated as work is finished -->
