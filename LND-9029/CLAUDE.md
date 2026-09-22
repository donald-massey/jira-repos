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

### query_1 — medium backlog scan (verify counts before any watermark reset)

Adapt `LND-9028/query_2/verify_coverage.py` into `query_1/verify_coverage.py` with one filter change:
replace the double `must_not` exclusion with a positive `must` term on `data.iie_priority: medium`.
Everything else (S3 package_id join, monthly windows, temp-table DB check, CSV output) is unchanged.

Run: `--start 2023-01-01 --end 2026-10-01 --out candidates_medium.csv`

The 2023 lower bound is intentional: the ticket's 861K figure came from an ES hits.total that
used an unverified join key (ES dataset_id ≠ DB dataset_id — different id spaces). The S3
package_id join is the only authoritative check. If someone wants pre-2023 history, this card
is the reference point for how to extend the scan.

**Do not reset the watermark until the scan completes.** The oldest unprocessed `created_at`
in the output is the correct reset target — not 2024-05-22 (unverified) from the ticket.

Key facts from LND-9028 that carry forward:
- ES field: `data.iie_priority`, value `"medium"` (positive match, no exclusions needed)
- Correct join: `records[0]["package_id"]` from S3 iie.json → `iie.instrument.package_id`
- DB join key: `dataset_id`-keyed joins produce 100% false misses — do not use them
- Empty datasets (records == []) are correct; loader skips them, not a gap
- Open a fresh DB connection per month — idle connections drop during long S3 fetches
- `S3_WORKERS=48` default; reduce if SSL/ConnectionClosed errors dominate the error log

## Completed

<!-- Updated as work is finished -->
