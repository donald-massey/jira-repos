# LND-9028: Backfill iie_diml_loader-high: Reset Watermark and Drain 129K Records

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9028
**Status:** CANDIDATE FOR DEV

**Summary**
The iie_diml_loader-high watermark in CS_Digital.dbo.loaderStatus advanced past a 6-month window of records due to the pre-LND-8967 finalize-on-cap bug. An ES count confirms 129,324 high-priority IIE records with created_at between 2026-05-26 and 2026-09-14 that were never loaded into CS_Digital.IIE.instrument. This card tracks resetting the watermark and monitoring the drain to completion.

**Given**
LND-8967 fixed the finalize-on-cap bug and capped runs at IIE_MAX_BATCHES=5. With that fix in prod, the loader can drain a historical backlog without runaway resource usage. Current watermark is approximately 2026-09-13. Resetting to 2026-03-14 (records begin at 2026-05-26 — the empty gap is skipped instantly by ES pagination) causes the loader to process oldest-first at ~11,379 records/day historical capacity, completing in ~12 calendar days.

Capacity model: 24 runs/day × 5 batches × 100 records = 12,000 rec/day total; 621 rec/day current inflow; 11,379 rec/day historical capacity. Backlog density: 1,165 rec/day (129,324 records over 111 days). Advance rate: ~9.77 historical days per calendar day.

**Expect**

* Watermark reset to 2026-03-14 in CS_Digital.dbo.loaderStatus for iie_diml_loader-high
* Loader drains 129,324 records over ~12 calendar days, oldest-first
* Daily monitoring via watermarks.sql confirms steady forward progress
* Watermark reaches 2026-09-14+ and loader returns to normal current-day operation

**Definition of Done**

- [ ] Watermark reset to 2026-03-14 (UPDATE run manually against CS_Digital.dbo.loaderStatus)
- [ ] Daily watermark progress verified via watermarks.sql for 12 days
- [ ] 129,324 records confirmed present in CS_Digital.IIE.instrument
- [ ] Loader operating normally on current-day inflow only

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
