# LND-9029: Backfill iie_diml_loader-medium: Reset Watermark and Drain 861K Records

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9029
**Status:** In Progress

**Summary**
The iie_diml_loader-medium watermark in CS_Digital.dbo.loaderStatus advanced past 861,385 medium-priority IIE records due to the pre-LND-8967 finalize-on-cap bug. The oldest unprocessed medium-priority record in ES dates to 2024-05-22T12:59:15Z. This card tracks resetting the watermark and monitoring the drain to completion.

**Given**
LND-8967 fixed the finalize-on-cap bug and capped runs at IIE_MAX_BATCHES=5. The medium loader window spans 2024-05-22 to 2026-09-14 (~845 days, ~1,019 records/day density). At 11,379 records/day historical capacity the drain takes approximately 76 calendar days. The medium backlog is substantially larger than high; weekly check-ins are sufficient once underway.

Capacity model: 24 runs/day × 5 batches × 100 records = 12,000 rec/day total; historical capacity after daily inflow = 11,379 rec/day. 861,385 / 11,379 ≈ 76 calendar days to drain.

**Expect**

- Watermark reset to 2024-05-22 in CS_Digital.dbo.loaderStatus for iie_diml_loader-medium
- Loader drains 861,385 records over ~76 calendar days, oldest-first
- Weekly monitoring via watermarks.sql confirms forward progress
- Watermark reaches current date and loader returns to normal daily operation

**Definition of Done**

- [ ] Watermark reset to 2024-05-22 (UPDATE run manually against CS_Digital.dbo.loaderStatus)
- [ ] Weekly watermark progress confirmed via watermarks.sql
- [ ] Loader operating normally on current-day inflow when complete

## Context from LND-9028 (High Backfill — Done)

LND-9028 used an ES count query to identify unprocessed IIE records by priority tier and date range. The method:
1. Query ES with `priority=medium` and `created_at` range filters to count unprocessed records
2. Scan oldest available `created_at` to find how far back the backlog extends
3. Compare ES count against CS_Digital.IIE.instrument to identify the gap

LND-9028 also found ~3,000 pre-2026 unprocessed records in the high tier during drain — the user wants to apply the same scan to the medium tier to verify the 861K figure and determine the oldest record date before resetting the watermark.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
