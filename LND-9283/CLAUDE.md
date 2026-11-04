# LND-9283: Fix Lease Exporter Stall From Unexportable TOP 500 Rows

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9283
**Status:** Ready for Dev

**Summary**
`ch-lease-exporter` selects `TOP 500` eligible records with no ORDER BY before its inner joins, so records that can never export keep taking pool slots. 688 are stuck, 8,504 exportable leases (97%) are starved in every county, and the exporter is effectively stalled (last `tblExportLog` write 2026-11-01). A fix lets unexportable rows stop consuming the pool and the backlog drain. Found in LND-7358.

**Steps to Reproduce**

1. Run the exporter's `get_records` filter (recordIsLease 1, StatusID 4/16, not in `tblExportLog`, fileDate >= 2002-01-01, excluded counties) with `TOP 500` and no ORDER BY (`LND-7358/query_13`).
2. Inner-join `tbllookupInstTypes`, grantor and grantee, as the exporter does.
3. Count how many of the 500 survive the joins, and compare the recordID range with exported records.

**Expected Behavior**
Every eligible, exportable record is reachable and exported within a run or two, regardless of recordID or county. Records failing a join do not hold slots.

**Actual Behavior**
The data fits the pool being the lowest 500 eligible recordIDs by string order. Rows failing a join never export and stay in the pool, so the reachable range shrinks as they accumulate (as of 2026-11-04):

- 688 records stuck. The 500th-lowest stuck recordID (the ceiling) is `bae26465-eb45-4ec7-ab7e-4c92d863b473`.
- 8,740 exportable leases waiting; 8,504 (97%) sit above the ceiling, 236 below.
- Once the 236 drain, the pool is 500 stuck rows and nothing exports for any county.
- Last `tblExportLog` write 2026-11-01 (about 20 leases).

Not verified against the live `get_records` ordering or the DEBUG log; the pool was reproduced from the filter text.

**What the 688 are**

- About 353 NM non-lease documents (Sandoval 255, Valencia 79, others; types NTP, DISCO, DPU, AMD, REOGL, STIPI) flagged recordIsLease 1, StatusID 4, no grantee. Loaded in four bulk loads 2026-08-10 to 08-12.
- 58 VOID and 5 BLNK (Denton, Jefferson, Howard TX), still arriving as of 2026-11-03.
- 62 with no instrument type (61 Lea NM from the 2022-11-23 load).
- About 205 real lease types (MOGL, OGL and so on) missing one grantor or grantee, in WV, PA, OH, LA, OK, TX.
- A few others (Hood, Concho MEM, Denton RE-REC, Bossier AMD, Wetzel OGASN).

**Impact / Severity**
Leases from every county stop reaching `tblExportLog`, so they never reach the producer, Kafka or DS9 `legal_lease`. Largest starved counties: WV Wetzel 523, WV Marion 475, WV Harrison 307, TX Midland 247, TX Leon 246, OK Beckham 180, WV Monongalia 161, OH Jefferson 160, LA Caddo 153, OH Belmont 152, plus about 260 more. Blocks the 43 Weld CO leases on LND-7358.

**Environment**
Prod. `ch-lease-exporter`, CSTitle `countyScansTitle.dbo.tblrecord`, `tblExportLog`.

**Evidence** (read-only CSTitle queries in `jira-repos/LND-7358`)

- `query_13`: reproduces the pool. 500 rows, 425 can never export.
- `query_14`: breakdown of those 425 by county, reason and month.
- `query_31`: Weld 43 all above the ceiling.
- `query_38`: all 688 stuck rows; result 4 is the re-key list.
- `query_39`: ceiling `bae26465`, 8,504 starved records by county and row.

**Proposed Fix**

1. Data (run manually, not scripted): set the non-lease and no-type rows to recordIsLease 0 and StatusID 17 (Filtered Non Lease Type, per LND-8655), or have data entry correct them. Re-key the lease-type rows from `query_38` result 4. Stuck rows drop below 500 and the backlog drains in batches of 500.
2. Code: move the instrument type, grantor and grantee inner joins inside the TOP and add an ORDER BY, so unexportable rows cannot hold slots.
3. Upstream: find out why NM bulk loads and VOID/BLNK records arrive with recordIsLease 1 (owner unknown: loader or data entry).

**Open Questions**

- Confirm the live `get_records` ordering and DEBUG log.
- Should NTP, DISCO, DPU, REOGL, RE-REC, VOID or BLNK ever carry recordIsLease 1?
- After clearing, do the 43 Weld records and the 8,504 export, and do Glue and DS9 keep up with the burst?

**Acceptance**

- Stuck rows below 500 and falling; `tblExportLog` receiving new rows daily for all counties.
- The 8,504 starved leases exported and present in DS9 `legal_lease`.
- The exporter query no longer lets unexportable rows consume the pool.

**User note (start-work):** First step is to investigate the records that aren't oil and gas lease instruments. REOGL is the only type that might legitimately be a lease; the others (NTP, DISCO, DPU, AMD, STIPI, VOID, BLNK, etc.) are likely not leases and were accidentally flagged recordIsLease 1.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
