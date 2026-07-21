# LND-7941 — OKCR Scraper: Missing Images Attempted Indefinitely

## Task
Analyze the OK County Records (OKCR) scraper's missing-image feature and bound the cost of
re-attempting image acquisition against the metered OKCR API. Deliverable is analysis + a
recommendation (Jira comment + reproducible SQL), **not** the code change. See `README.md` for the
full analysis.

## Decision (Tyler Jordan)
Gate the missing-image check to a **1st-of-the-month** cadence: `GetMissingImages()` runs only when
the day of month = 1 (~12×/year) rather than every run. This **supersedes** the per-county
age-cutoff / `tblCountyLookup.image_retry_cutoff_days` mechanism originally proposed — no schema
change, no cutoff column. The per-county lag analysis stays as the justification for why frequent
retries are wasteful (backfills span 300–580 days). Note: a monthly cadence cuts frequency but does
not itself stop retrying never-resolving records (Roger Mills, dropped counties), so a one-time
permanent-exclusion pass on those is still worth doing separately.

## The problem
The scraper (`cygnus.cx1-ok-county-records-scraper`, C#/.NET) re-attempts image acquisition for
every record still missing an image, on every run, with no time bound — hitting a **metered**
OKCR API once per record indefinitely. Records that will never get an image are re-tried forever.

- `Database.GetMissingImages()` — `SELECT ... FROM okcr.instrument WHERE image_file_exists = 0`
  with no date bound. Drives one paid API call per row (`MissingImages.cs` → `okApi.GetInstrument`).
- `MissingImages.cs:140` handles `402: unable to collect payment` — confirms API calls cost money.
- `SKIP_MISSING_IMAGES` env flag already exists (`Configuration.cs:66`), so a job-split is partly wired.
- Loader side (`diml-loaders/.../okcountyrecords_loader.py`, `process_missing_images`) re-scans all
  `results_images` datasets each run and backfills `okcr.instrument`; it stamps `_ModifiedDateTime`
  when it flips `image_file_exists = 1`. This is the presumed sole post-insert writer to the table.

## Data source
- Prod `CS_Digital.okcr.instrument`, **read-only**.
- Scraped/first-seen anchor = `_CreatedDateTime`. Image-acquired anchor = `_ModifiedDateTime`
  on `image_file_exists = 1` rows. **Both anchors must be validated before use** (see README.md).

## Repos referenced
- Scraper (source of the cost): `enverus-cts/cygnus.cx1-ok-county-records-scraper` (C#/.NET).
- Loader (backfills the table): `diml-loaders/diml_loaders/okcountyrecords/`.

## Deliverable
- Comment on the Jira card (per the team Jira format).
- Reproducible SQL + analysis script committed to this repo.

## Conventions
- Windows/PowerShell shell. Match exact SQL column casing (`_CreatedDateTime`, not lowercase).
- Return actual rows for data requests unless counts/summaries are asked for.