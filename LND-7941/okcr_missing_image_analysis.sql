/*
    LND-7941 — OKCR missing-image cutoff analysis
    Target: prod CS_Digital.okcr.instrument (READ-ONLY)

    Run the sections in order. Sections 1a-1c VALIDATE the anchors; do not trust the
    cutoff in Section 2/3 unless validation passes. See README.md for rationale.

    Anchors:
      first-seen     = _CreatedDateTime
      image-acquired = _ModifiedDateTime  (loader's process_missing_images stamps this
                       when it flips image_file_exists 0 -> 1; it is the presumed sole
                       post-insert writer)
    lag_days = _ModifiedDateTime - _CreatedDateTime, in fractional days.
*/

-- Rows inserted WITH an image have _ModifiedDateTime ~= _CreatedDateTime and must be
-- excluded from the backfilled population. Section 1b validates this threshold.
DECLARE @ArrivedWithImageThresholdMinutes int = 60;

-- Optional: exclude a bulk-load/migration cliff found in Section 1a (NULL = no cutoff).
DECLARE @HistoryStart datetime = NULL;

/* ============================================================================
   1a. ANCHOR VALIDATION — _CreatedDateTime histogram by month.
   Look for spikes: a single month holding a huge share = a bulk load/migration,
   whose rows must be excluded (set @HistoryStart above) or the lag is fiction.
   OUTPUT CSV: okcr_1a_created_month_histogram.csv
   ============================================================================ */
SELECT
    DATEADD(month, DATEDIFF(month, 0, _CreatedDateTime), 0) AS created_month,
    COUNT(*)                                                AS n
FROM CS_Digital.okcr.instrument
GROUP BY DATEADD(month, DATEDIFF(month, 0, _CreatedDateTime), 0)
ORDER BY created_month;

/* ============================================================================
   1b. ANCHOR VALIDATION — lag distribution for image_file_exists = 1 rows.
   Expect BIMODAL: a near-zero cluster (arrived-with-image) and a positive cluster
   (genuinely backfilled). Confirms @ArrivedWithImageThresholdMinutes cleanly splits
   the two before we exclude the near-zero cluster.
   OUTPUT CSV: okcr_1b_lag_distribution.csv
   ============================================================================ */
WITH lag AS (
    SELECT DATEDIFF(second, _CreatedDateTime, _ModifiedDateTime) / 86400.0 AS lag_days
    FROM CS_Digital.okcr.instrument
    WHERE image_file_exists = 1
      AND document_dataset_id IS NOT NULL
)
SELECT bucket, COUNT(*) AS n
FROM (
    SELECT CASE
        WHEN lag_days < 1.0/1440 THEN '0: <1 min'
        WHEN lag_days < 1.0/24   THEN '1: <1 hr'
        WHEN lag_days < 1        THEN '2: <1 day'
        WHEN lag_days < 7        THEN '3: 1-7 days'
        WHEN lag_days < 30       THEN '4: 7-30 days'
        WHEN lag_days < 90       THEN '5: 30-90 days'
        WHEN lag_days < 365      THEN '6: 90-365 days'
        ELSE                          '7: >365 days'
    END AS bucket
    FROM lag
) b
GROUP BY bucket
ORDER BY bucket;

/* ============================================================================
   1c. ANCHOR VALIDATION — distinct writers to backfilled rows.
   NOTE: process_missing_images updates _ModifiedDateTime but NOT _ModifiedBy, so
   _ModifiedBy reflects the creator. Use this only to detect an unexpected foreign
   writer to the table (which would pollute _ModifiedDateTime as the acquired anchor).
   OUTPUT CSV: okcr_1c_writers.csv
   ============================================================================ */
SELECT _ModifiedBy, COUNT(*) AS n
FROM CS_Digital.okcr.instrument
WHERE image_file_exists = 1
GROUP BY _ModifiedBy
ORDER BY n DESC;

/* ============================================================================
   2. PER-COUNTY ACQUISITION-LAG STATS (the cutoff table + sensitivity).
   Population: genuinely backfilled records only.
   p95 is the recommended cutoff; p99 / p99.9 are the sensitivity columns.
   OUTPUT CSV: okcr_2_per_county_cutoffs.csv
   ============================================================================ */
WITH backfilled AS (
    SELECT
        county,
        DATEDIFF(second, _CreatedDateTime, _ModifiedDateTime) / 86400.0 AS lag_days
    FROM CS_Digital.okcr.instrument
    WHERE image_file_exists = 1
      AND document_dataset_id IS NOT NULL
      AND _ModifiedDateTime > DATEADD(minute, @ArrivedWithImageThresholdMinutes, _CreatedDateTime)
      AND (@HistoryStart IS NULL OR _CreatedDateTime >= @HistoryStart)
)
SELECT DISTINCT
    county,
    COUNT(*)          OVER (PARTITION BY county)                                AS acquired_n,
    CAST(MIN(lag_days)  OVER (PARTITION BY county) AS decimal(10,2))            AS min_days,
    CAST(AVG(lag_days)  OVER (PARTITION BY county) AS decimal(10,2))            AS mean_days,
    CAST(MAX(lag_days)  OVER (PARTITION BY county) AS decimal(10,2))            AS max_days,
    CAST(PERCENTILE_CONT(0.50)  WITHIN GROUP (ORDER BY lag_days) OVER (PARTITION BY county) AS decimal(10,2)) AS p50_days,
    CAST(PERCENTILE_CONT(0.95)  WITHIN GROUP (ORDER BY lag_days) OVER (PARTITION BY county) AS decimal(10,2)) AS p95_days,
    CAST(PERCENTILE_CONT(0.99)  WITHIN GROUP (ORDER BY lag_days) OVER (PARTITION BY county) AS decimal(10,2)) AS p99_days,
    CAST(PERCENTILE_CONT(0.999) WITHIN GROUP (ORDER BY lag_days) OVER (PARTITION BY county) AS decimal(10,2)) AS p999_days
FROM backfilled
ORDER BY county;

/* ============================================================================
   3. PAYOFF — records still missing an image that are OLDER than the county's
   p95 cutoff. missing_older_than_cutoff ~= paid API calls/run saved per county.
   Counties with < @MinSampleN acquired records are flagged: their per-county p95
   is noise and should fall back to a pooled cutoff (compute pooled separately).
   Dropped/no-longer-hosted counties (Creek, Grady, ...) still appear here — annotate
   them for PERMANENT exclusion rather than a time cutoff.
   OUTPUT CSV: okcr_3_payoff.csv
   ============================================================================ */
DECLARE @MinSampleN int = 50;

WITH backfilled AS (
    SELECT
        county,
        DATEDIFF(second, _CreatedDateTime, _ModifiedDateTime) / 86400.0 AS lag_days
    FROM CS_Digital.okcr.instrument
    WHERE image_file_exists = 1
      AND document_dataset_id IS NOT NULL
      AND _ModifiedDateTime > DATEADD(minute, @ArrivedWithImageThresholdMinutes, _CreatedDateTime)
      AND (@HistoryStart IS NULL OR _CreatedDateTime >= @HistoryStart)
),
cutoffs AS (
    SELECT
        county,
        acquired_n,
        CAST(CEILING(p95_raw) AS int) AS p95_days
    FROM (
        SELECT DISTINCT
            county,
            COUNT(*) OVER (PARTITION BY county) AS acquired_n,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY lag_days) OVER (PARTITION BY county) AS p95_raw
        FROM backfilled
    ) x
)
SELECT
    c.county,
    c.acquired_n,
    c.p95_days,
    CASE WHEN c.acquired_n < @MinSampleN THEN 'LOW SAMPLE - use pooled cutoff' ELSE '' END AS sample_flag,
    COUNT(i.package_id)                                                                         AS missing_total,
    SUM(CASE WHEN i._CreatedDateTime < DATEADD(day, -c.p95_days, GETDATE()) THEN 1 ELSE 0 END)  AS missing_older_than_cutoff
FROM cutoffs c
JOIN CS_Digital.okcr.instrument i
    ON i.county = c.county
   AND i.image_file_exists = 0
GROUP BY c.county, c.acquired_n, c.p95_days
ORDER BY missing_older_than_cutoff DESC;

/* ============================================================================
   3b. POOLED cutoff across ALL active counties (fallback for low-sample counties).
   Manually exclude dropped counties from this pool before quoting it.
   OUTPUT CSV: okcr_3b_pooled_cutoff.csv
   ============================================================================ */
WITH backfilled AS (
    SELECT DATEDIFF(second, _CreatedDateTime, _ModifiedDateTime) / 86400.0 AS lag_days
    FROM CS_Digital.okcr.instrument
    WHERE image_file_exists = 1
      AND document_dataset_id IS NOT NULL
      AND _ModifiedDateTime > DATEADD(minute, @ArrivedWithImageThresholdMinutes, _CreatedDateTime)
      AND (@HistoryStart IS NULL OR _CreatedDateTime >= @HistoryStart)
      -- AND county NOT IN ('CREEK','GRADY', ...)   -- exclude dropped counties
)
SELECT DISTINCT
    COUNT(*)                                                           OVER () AS acquired_n,
    CAST(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY lag_days) OVER () AS decimal(10,2)) AS pooled_p95_days,
    CAST(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY lag_days) OVER () AS decimal(10,2)) AS pooled_p99_days
FROM backfilled;
