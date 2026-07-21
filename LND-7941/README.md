<!-- exec-summary:start -->
## Executive Summary

**TL;DR**
The OKCR scraper re-hits a metered API for every image-less record on every run, forever — wasting
spend on records that will never resolve. Analysis of `CS_Digital.okcr.instrument` shows backfills
span 300–580 days per county, so frequent retries buy no coverage. **Decision (Tyler Jordan): gate
the missing-image check to the 1st of the month** — `GetMissingImages()` runs only when day-of-month
= 1 (~12×/year, ~97% fewer runs), superseding the per-county age-cutoff column originally proposed.
Analysis done; Jira comment posted (LND-7941 comment 5013335).

**Action Items**
1. **Ask Tyler:** the 1st-of-month gate cuts *frequency* but never *stops* retrying dead records —
   Roger Mills alone is ~68k API calls/year (5,663 × 12). Add a one-time permanent-exclusion pass for
   dropped/dead counties (Creek, Grady, Roger Mills) alongside the cadence change?
2. File follow-up tickets: enforcement (gate `GetMissingImages()` to day-of-month = 1 via
   `SKIP_MISSING_IMAGES`), monitoring (402 / error-rate alerts).
3. Decide Roger Mills: investigate why acquisition broke (5,663 missing, 97% never resolve) vs
   permanently exclude it.

**Key Findings / Status**
- Decision: 1st-of-month gate (Tyler Jordan) — ~97% fewer missing-image runs (≈365→12/year), no
  schema change; supersedes the per-county `tblCountyLookup.image_retry_cutoff_days` cutoff column.
- Caveat to raise with Tyler: the monthly cadence reduces *frequency* but doesn't *bound*
  never-resolving records; a permanent-exclusion pass on dead counties still has value (Roger Mills
  is ~68k calls/year on its own).
- Anchors validated: 434,170 rows arrived with an image (<1 hr, excluded) vs 21,928 genuine
  backfills; the 60-min split is clean.
- Per-county lag spans ~60 to ~580 days — the evidence that frequent retries buy no coverage and
  daily runs are wasteful (backs the monthly cadence).
- Payoff: ~6,783 of ~9,803 per-run calls were older than a p95 cutoff (Roger Mills alone 5,639); the
  monthly gate captures that frequency waste more simply.
- Caveats: bulk-load spikes in `_CreatedDateTime` (Sep-2020, Dec-2021→Feb-2022, Apr-2025); 648 rows
  last-touched by `LND-6879`, not the loader, so `_ModifiedDateTime` isn't a pure anchor for those.
<!-- exec-summary:end -->

# LND-7941 — OKCR Missing-Image Cutoff

## Task
Analyze the OK County Records (OKCR) scraper's missing-image feature and recommend a
**per-county cutoff** — how many days after a record is first seen the scraper should stop
attempting image acquisition. Deliverable is analysis + a recommended cutoff (a Jira card comment
plus reproducible SQL in this repo), **not** the code change. Enforcement, job-split, and
monitoring are follow-ups.

## The problem
The scraper (`cygnus.cx1-ok-county-records-scraper`, C#/.NET) re-attempts image acquisition for
every record still missing an image, on every run, with no time bound — hitting a **metered**
OKCR API once per record indefinitely. Records whose images will never arrive burn API spend
forever. A time cutoff bounds that waste; this analysis produces the defensible number.

- `Database.GetMissingImages()` — `SELECT ... FROM okcr.instrument WHERE image_file_exists = 0`,
  no date bound. Drives one paid API call per row (`MissingImages.cs` → `okApi.GetInstrument`).
- `MissingImages.cs:140` handles `402: unable to collect payment` — confirms the calls cost money.
- `SKIP_MISSING_IMAGES` env flag already exists (`Configuration.cs:66`), so a job-split is partly wired.
- Loader side (`diml-loaders/.../okcountyrecords_loader.py`, `process_missing_images`) re-scans all
  `results_images` datasets each run and backfills `okcr.instrument`, stamping `_ModifiedDateTime`
  when it flips `image_file_exists = 1`. Presumed sole post-insert writer to the table.

## Data source
- Prod `CS_Digital.okcr.instrument`, **read-only**.
- First-seen anchor = `_CreatedDateTime`. Image-acquired anchor = `_ModifiedDateTime` on
  `image_file_exists = 1` rows. Both anchors were validated before use (see Method / Findings).

## Method

### Step 1 — Validate the anchors (gates everything else)
1. Histogram `_CreatedDateTime` by month → detect bulk-load / migration cliffs (e.g. LND-6732-style
   migrations). Exclude or annotate any spike so it doesn't corrupt age buckets.
2. Confirm `process_missing_images` is the **only** post-insert writer to `okcr.instrument`. If so,
   `_ModifiedDateTime` on `image_file_exists = 1` rows is a clean acquisition proxy. If not, fall
   back to the `results_images` dataset creation time from DIML ES.

### Step 2 — Build the acquisition-lag distribution (hazard framing, not mean-of-successes)
- For each acquired record: `lag = _ModifiedDateTime − _CreatedDateTime`.
- Mean-of-successes is wrong — it's conditioned on success and ignores the never-acquired backlog
  that is the actual cost. Use the lag **CDF**: the age by which X% of eventual acquisitions have
  happened. The cutoff is where the curve flattens.
- **Separate "arrived-with-image" rows** (`_ModifiedDateTime ≈ _CreatedDateTime`, near-zero lag)
  from genuinely backfilled rows, or they drag the percentile down. Distribution is bimodal; the
  split was validated empirically rather than hard-coding an epsilon blind.

### Step 3 — Segment per county (a global cutoff is rejected)
1. **Dropped / no-longer-hosted counties** (Creek, Grady, others not on OKCountyRecords.com) →
   recommend **permanent exclusion** from the missing-image query. Their chance of ever acquiring
   is zero regardless of age; a time cutoff is the wrong tool, and they poison the curves.
2. **Active counties with ≥ 50 acquired records** → own per-county curve and cutoff.
3. **Sparse counties (< 50)** → fall back to a fixed **37-day** default (1 month + 1 week); their
   own curve is noise. (Pooled p95 is still computed in the SQL as a reference — see `okcr_3b`.)

### Step 4 — Choose the cutoff
- Per county: **cutoff = p95** of ever-acquired lag, rounded up to a whole week + small buffer.
- p95 leans toward API savings, accepting the risk of dropping the slow ~5% tail.
- Report a **sensitivity table (p95 / p99 / p99.9)** with corresponding cutoff and "records dropped"
  count, plus min/mean/median/max, so the pick is defensible.

### Confounders — handled by monitoring, not modeling
Some still-missing records are missing due to `402` payment failures / API outages, not because the
image is absent — indistinguishable in the DB. Transient failures just lengthen lag and the CDF
absorbs them; only a sustained outage would bias a window. Do **not** build a failure-vs-absent
classifier off `image_file_exists`. Instead caveat it and recommend a monitoring follow-up
(Serilog → Grafana) on 402 / error-rate spikes.

## Findings

- **Anchors validated.** `csv/okcr_1b_lag_distribution.csv` is cleanly bimodal — 434,170 rows arrived
  *with* an image (<1 hr) vs **21,928 genuine backfills**. The 60-min threshold splits them cleanly.
- **Two caveats found.** `csv/okcr_1a_created_month_histogram.csv` shows bulk-load spikes in
  `_CreatedDateTime` (2020-09: ~19k, 2021-12→2022-02: ~53k, 2025-04: ~42k).
  `csv/okcr_1c_writers.csv` shows a foreign writer — **`LND-6879` last-touched 648 rows**, so
  `_ModifiedDateTime` isn't a pure acquisition anchor for those.
- **Per-county was clearly right.** p95 ranges from ~60 days (Garvin, Muskogee, Pittsburg) to ~580
  (Kiowa, Seminole, Love). A global cutoff would have been badly wrong.
- **Headline:** ~6,783 of ~9,803 per-run missing-image API calls are older than their county's p95
  cutoff (~69% eliminable) — but **Roger Mills alone is 5,639 of that (83%)**: 5,663 missing vs only
  174 ever acquired (97% never resolve). Not a "tune the cutoff" county — a "something's broken / drop
  it" county.

## Recommended per-county cutoffs (ranked by calls saved/run)

| County | Acquired | p95 cutoff (days) | Missing | Saved/run | Note |
|---|---|---|---|---|---|
| Roger Mills | 174 | 330 | 5,663 | 5,639 | ⚠ investigate / likely exclude |
| Major | 148 | 317 | 298 | 238 | |
| Stephens | 6,146 | 508 | 340 | 134 | |
| LeFlore | 5,165 | 533 | 762 | 108 | |
| McClain | 313 | 316 | 135 | 99 | |
| Comanche | 1,234 | 498 | 135 | 67 | |
| Noble | 82 | 227 | 58 | 55 | |
| Garvin | 377 | 66 | 78 | 49 | |
| Carter | 347 | 370 | 53 | 48 | |
| Okmulgee | 87 | 66 | 48 | 47 | |
| Muskogee | 231 | 66 | 44 | 44 | |
| Ellis | 99 | 66 | 29 | 29 | |
| Texas | 36 | 490 | 30 | 27 | low sample → pooled |
| Washington | 80 | 309 | 21 | 19 | |
| Custer | 321 | 278 | 442 | 19 | |
| Hughes | 138 | 67 | 18 | 17 | verify pipeline |
| Blaine | 1,065 | 548 | 1,099 | 16 | |
| Pittsburg | 218 | 64 | 16 | 16 | |
| Kingfisher | 307 | 305 | 19 | 13 | |
| Dewey | 124 | 315 | 16 | 11 | |
| Harper | 49 | 490 | 16 | 10 | low sample → pooled |
| Grant | 17 | 490 | 9 | 9 | low sample → pooled |
| Beckham | 60 | 330 | 16 | 9 | |
| McIntosh | 38 | 490 | 9 | 8 | low sample → pooled |
| Haskell | 2,022 | 503 | 10 | 7 | verify pipeline |
| Lincoln | 180 | 318 | 26 | 6 | |
| Woodward | 82 | 309 | 7 | 6 | |
| Alfalfa | 96 | 66 | 8 | 6 | verify pipeline |
| Coal | 34 | 490 | 181 | 5 | low sample → pooled |
| Pontotoc | 177 | 62 | 5 | 4 | |
| Latimer | 91 | 319 | 4 | 4 | |
| Kay | 175 | 61 | 5 | 3 | |
| Seminole | 91 | 564 | 25 | 2 | |
| Atoka | 87 | 66 | 2 | 2 | |
| Jackson | 102 | 130 | 25 | 2 | |
| Bryan | 27 | 490 | 1 | 1 | low sample → pooled |
| Love | 240 | 550 | 102 | 1 | |
| Johnston | 19 | 490 | 3 | 1 | low sample → pooled |
| Logan | 445 | 357 | 3 | 1 | |
| Marshall | 19 | 490 | 1 | 1 | low sample → pooled |
| Jefferson | 844 | 475 | 1 | 0 | |
| Kiowa | 39 | 490 | 2 | 0 | low sample → pooled |
| Okfuskee | 53 | 64 | 1 | 0 | |
| Murray | 60 | 480 | 35 | 0 | |
| Harmon | 3 | 490 | 1 | 0 | low sample → pooled |

Full descriptive stats (min/mean/median/max + p99/p99.9) in `csv/okcr_2_per_county_cutoffs.csv`;
payoff detail in `csv/okcr_3_payoff.csv`; pooled fallback in `csv/okcr_3b_pooled_cutoff.csv`.

## Recommended enforcement mechanism

**Decision (Tyler Jordan): gate the missing-image check to the 1st of the month.** `GetMissingImages()`
runs only when the day of month = 1 (~12×/year) instead of every run — ~97% fewer missing-image API
runs while staying well inside every county's 300–580-day backfill window.

- **Gate:** short-circuit the missing-image routine unless the run date is the 1st of the month;
  `SKIP_MISSING_IMAGES` (`Configuration.cs:66`) is already wired to skip the check.
- **No schema change.** Supersedes the originally proposed per-county age-cutoff column
  (`tblCountyLookup.image_retry_cutoff_days`) — simpler to operate, no per-county recompute.
- **Residual (open, for Tyler):** a monthly cadence reduces *frequency* but does not *stop* retrying
  records that will never resolve — Roger Mills alone is ~68k calls/year (5,663 × 12). A one-time
  permanent-exclusion pass on dropped/dead counties (Creek, Grady, Roger Mills) still has value on
  top of the cadence gate.

The per-county lag analysis above stands as the justification for the cadence — it is why daily (or
twice-weekly) retries buy no coverage.

## Open calls

1. **Permanent exclusion (raise with Tyler).** The 1st-of-month gate cuts frequency but never stops
   retrying dead records — Roger Mills alone is ~68k calls/year (5,663 × 12). Recommend a one-time
   permanent-exclusion pass on dropped/dead counties (Creek, Grady, Roger Mills) alongside the
   cadence change.
2. **Roger Mills.** 5,663 missing vs 174 ever acquired (97% never resolve) — acquisition appears
   broken, not slow. Investigate why (dropped from OKCountyRecords like Creek/Grady?) or exclude it.

## Follow-up tickets (out of scope for LND-7941)
- **Enforcement:** gate `GetMissingImages()` to run only when day-of-month = 1 (~12×/year), using the
  existing `SKIP_MISSING_IMAGES` flag (`Configuration.cs:66`) on non-1st runs. No schema change.
- **Permanent exclusion (pending Tyler):** one-time pass to permanently exclude dropped/dead counties
  (Creek, Grady, Roger Mills) from the missing-image query, independent of the cadence gate.
- **Monitoring:** alert on 402 / API-error spikes so failures are caught operationally.

## Artifacts in this repo
- `okcr_missing_image_analysis.sql` — anchor-validation (1a–1c), per-county lag/cutoff (2),
  payoff (3), pooled fallback (3b). Run sections in order.
- `csv/` — output CSVs for each section.
