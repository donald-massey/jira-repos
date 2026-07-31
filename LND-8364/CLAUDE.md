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

## Findings

### Step 1 — tblexportLog results (mi-exportlog-check.sql)

| recordID | recordNumber | fileDate | leaseID | zipName |
|---|---|---|---|---|
| 9504fdef-c20b-42f8-9cce-09a3991e9223 | 2026-00050 | 2026-01-08 | 5250533 | CH_04.21.2026.13.44_leases |
| 2f27f271-3a42-4329-813c-ba15bdc4b1b5 | 000000NA | 2022-10-28 | NULL | CH_11.15.2022.19.00_leases |
| cd130801-8bad-48c3-bce2-81336b1f2e14 | 202300002307 | 2023-08-07 | NULL | CH_09.04.2023.17.21_leases |

MISSAUKEE passes Level 1. ALPENA and ALCONA are Level 1 failures — IIF never created a DIV1 entry for either.

### Step 2 — DIV1 abstract mapping (mi-div1-mapping-check.sql)

Only MISSAUKEE (leaseID 5250533) is eligible — ALPENA and ALCONA excluded by `AND el.leaseID IS NOT NULL`.

| leaseID | record_id | recordNumber | mapping_count | status |
|---|---|---|---|---|
| 5250533 | 9504fdef-c20b-42f8-9cce-09a3991e9223 | 2026-00050 | 0 | NO MAPPING — fix applies |

MISSAUKEE confirmed Level 2. The proposed fix covers it exactly.

### Archive search — Level 1 recoverability

Checked `\\smb.dc2isilon.na.drillinginfo.com\lease_data_entry\ch_lease_exporter\input\processed\` for the two Level 1 zips. Archive goes back to 2019 and has 1,100+ zips from both 2022 and 2023, so the absence is meaningful.

**ALPENA** (`CH_11.15.2022.19.00_leases`): Nov 15, 2022 is entirely absent from the processed archive. Nov 14 runs through `22.01` then jumps to Nov 16 — zero zips from Nov 15 exist. The entire date was skipped; the zip is not recoverable.

**ALCONA** (`CH_09.04.2023.17.21_leases`): All other Sep 4, 2023 zips are present (17.00, 18.00, 18.21, 19.00, 22.00) but `17.21` specifically is missing. Not recoverable from archive.

Errors folder (`input/errors/`) is empty. No other archive location found.

### Step 3 — tblLandDescription check (mi-land-descriptions-check.sql)

| record_id | source | row_count |
|---|---|---|
| 2f27f271-3a42-4329-813c-ba15bdc4b1b5 (ALPENA) | tblLandDescription | 1 |
| cd130801-8bad-48c3-bce2-81336b1f2e14 (ALCONA) | tblLandDescription | 7 |
| 9504fdef-c20b-42f8-9cce-09a3991e9223 (MISSAUKEE) | — | 0 |

ALPENA and ALCONA have land descriptions in CSTitle — document-type limitation is ruled out, both are legitimate leases dropped by an IIF timing race. MISSAUKEE has no rows; its land description path runs through DIV1 via the abstract mapping, which is the broken link. The fix will publish MISSAUKEE to ES but the record will be sparse until the abstract mapping exists.

These results don't change the fix path — repairing Level 1 records via CSTitle data is not the approach; the proposed fix (publish unmapped leases to ES, skip DS9) remains the path forward for all three.

### Fix coverage summary

| Record | leaseID | Level | Fix covers? | Notes |
|---|---|---|---|---|
| MISSAUKEE 2026-00050 | 5250533 | 2 — no abstract mapping | **Yes** | |
| ALCONA 202300002307 | NULL | 1 — IIF never ran | **No** | Zip missing from archive; entire Sep 4 17.21 batch absent |
| ALPENA 000000NA | NULL | 1 — IIF never ran | **No** | Entire Nov 15 2022 date absent from archive |

**The proposed fix covers 1 of 3 reported MI records.** ALCONA and ALPENA require manual remediation — re-export via ch-lease-exporter for those recordIDs, or manual IIF re-run with zip reconstructed from countyScansTitle.

### Step 4 — MI county-level drop rate (mi-drop-rate.sql)

| county_name | candidate_leases | has_mapping | no_mapping | pct_dropped |
|---|---|---|---|---|
| Montmorency | 7 | 5 | 2 | 28.57 |
| Kalkaska | 186 | 178 | 8 | 4.30 |
| Presque Isle | 49 | 48 | 1 | 2.04 |
| Manistee | 409 | 404 | 5 | 1.22 |
| Wexford | 93 | 92 | 1 | 1.08 |
| Grand Traverse | 292 | 289 | 3 | 1.03 |
| Otsego | 99 | 98 | 1 | 1.01 |
| Missaukee | 351 | 349 | 2 | 0.57 |
| (15 counties) | — | — | 0 | 0.00 |

**23 total unmapped (Level 2) records across 8 MI counties.** The proposed fix covers all of them. Montmorency's 28.57% rate is an artifact of a tiny denominator (7 leases). Rates elsewhere are 1–4%, consistent with normal pipeline variance. Counties with 0 no_mapping are fully mapped and unaffected.

ALCONA (7 leases) and ALPENA (27 leases) both show 0 no_mapping here — their known Level 1 failures have NULL leaseIDs and are excluded from this query, which filters on records that reached DIV1.

## Completed
