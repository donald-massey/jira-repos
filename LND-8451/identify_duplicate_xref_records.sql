-- LND-8451: duplicate xref rows — one recordID bound to two package_ids
-- (Shape 2, split off from LND-6796). Identify the records and pivot each to its
-- two package_ids for the DIML same-PDF check.
--
-- All tables are local to CS_Digital (no linked server). Column casing follows the
-- cs-digital-mfg loader's own SQL; verify against the schema if it has drifted.
--
-- HOW TO RUN: the three steps below are independent SELECTs — run them in one SSMS
-- window. Step B builds #dup/#pairs (session-scoped temp tables); Step C reads them,
-- so run B before C. Save Step C's result set as shape2_pairs.csv (with header) —
-- it is the default input for LND-8451_diml_pdf_check.py.
--
-- These recordIDs are DUPLICATED in tblDimlXref (present more than once). That makes
-- this set disjoint from the orphaned-xref cleanup (recordIDs ABSENT from tblRecord)
-- and from the cross-county correctness set (records present exactly once but
-- disagreeing on county/document). tblRecord itself has no duplicate rows.


/* ===========================================================================
   A. DUPLICATE XREF ROWS — every recordID with >1 xref row, one row per
      (recordID, package_id). Export as LND-8451(C).csv. ~4,500 recordIDs ->
      ~9,000 rows (data shows exactly two rows each). No staging table needed:
      this covers ALL recordIDs and is local-only, so it is fast as-is.
   =========================================================================== */
WITH dup_records AS (
    SELECT RecordID
    FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY RecordID
    HAVING COUNT(*) > 1
)
SELECT
    x.RecordID,
    x.package_id
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN dup_records d ON d.RecordID = x.RecordID
ORDER BY x.RecordID;


/* ===========================================================================
   B. SHAPE 2 PAIRS — pivot each duplicate recordID to its two package_ids
      side-by-side, with the record's own county/state and originalFileName for
      context. This is the input for the DIML same-PDF check.

      Runs in narrow steps to avoid the wide-text GROUP BY + tempdb spill that
      made a single-statement version take ~30 min:
        1. #dup   — recordIDs with >1 xref row, materialized once.
        2. #pairs — pivot package_ids over the SMALL dup set only (no joins).
        3. context — attach county/state/originalFileName as 1:1 lookups.
      pkg_count flags any recordID with MORE than two rows (data shows all = 2).
      For a smoke test, add TOP (N) to step 3 (optionally ORDER BY NEWID()).
   =========================================================================== */
IF OBJECT_ID('tempdb..#dup')   IS NOT NULL DROP TABLE #dup;
IF OBJECT_ID('tempdb..#pairs') IS NOT NULL DROP TABLE #pairs;

-- 1. dup recordIDs, materialized once and keyed
SELECT RecordID
INTO #dup
FROM [CS_Digital].[dbo].[tblDimlXref]
GROUP BY RecordID
HAVING COUNT(*) > 1;
ALTER TABLE #dup ADD PRIMARY KEY (RecordID);

-- 2. pivot package_ids over the small set only (narrow aggregate, no joins)
WITH ranked AS (
    SELECT
        x.RecordID,
        x.package_id,
        ROW_NUMBER() OVER (PARTITION BY x.RecordID ORDER BY x.package_id) AS rn,
        COUNT(*)     OVER (PARTITION BY x.RecordID)                       AS pkg_count
    FROM [CS_Digital].[dbo].[tblDimlXref] x
    JOIN #dup d ON d.RecordID = x.RecordID
)
SELECT
    RecordID,
    MAX(CASE WHEN rn = 1 THEN package_id END) AS package_id_1,
    MAX(CASE WHEN rn = 2 THEN package_id END) AS package_id_2,
    MAX(pkg_count)                            AS pkg_count
INTO #pairs
FROM ranked
GROUP BY RecordID;
ALTER TABLE #pairs ADD PRIMARY KEY (RecordID);

-- 3. attach context as 1:1 lookups (no aggregation).
--    Save THIS result set as shape2_pairs.csv (with header) — the default input
--    for LND-8451_diml_pdf_check.py.
SELECT
    p.RecordID,
    p.package_id_1,
    p.package_id_2,
    p.pkg_count,
    lc.CountyName        AS recordCounty,
    ls.StateAbbreviation AS recordState,
    r.originalFileName   AS recordOriginalFileName
FROM #pairs p
-- LEFT JOIN (not INNER): ~1,670 of the ~4,500 dup recordIDs have no tblRecord row
-- (orphaned xref rows). They still carry duplicate package_ids and must stay in the
-- export for the DIML check / dedupe; context columns are just NULL for them.
LEFT JOIN [CS_Digital].[dbo].[tblRecord] r          ON r.recordID  = p.RecordID
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID = r.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates] ls   ON ls.StateID  = lc.StateID
ORDER BY p.RecordID;


/* ===========================================================================
   C. LIVE vs ORPHAN split — quantify how many duplicate recordIDs have a live
      tblRecord row (the population the producer can ever pull) vs none (orphaned
      xref rows, cleanup only). Run after Step B (reads #pairs).
   =========================================================================== */
-- 1. quantify (expect ~4,500 total / ~1,670 missing)
SELECT COUNT(*)                                            AS pairs_total,
       SUM(CASE WHEN r.recordID IS NULL THEN 1 ELSE 0 END) AS missing_in_tblRecord
FROM #pairs p
LEFT JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = p.RecordID;

-- 2. orphan vs case/whitespace artifact: take one missing id, probe exact then
--    normalized. Both returning 0 confirms a genuine orphan, not a collation issue.
SELECT TOP 1 p.RecordID
FROM #pairs p LEFT JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = p.RecordID
WHERE r.recordID IS NULL;   -- copy the value into <id> below

SELECT 'exact'      AS probe, COUNT(*) FROM [CS_Digital].[dbo].[tblRecord] WHERE recordID = '<id>'
UNION ALL
SELECT 'normalized', COUNT(*) FROM [CS_Digital].[dbo].[tblRecord] WHERE LOWER(LTRIM(RTRIM(recordID))) = LOWER(LTRIM(RTRIM('<id>')));
