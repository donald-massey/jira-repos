-- LND-6796: tblDimlXref shared package_id — identify affected records
-- https://enverus.atlassian.net/browse/LND-6796
--
-- All tables local to CS_Digital. No lower() in joins (default CI collation
-- matches case anyway and stays sargable). Column casing follows the loader's
-- own SQL (cs-digital-mfg new_record_query.sql); adjust if the schema differs.
--
-- HOW TO RUN: execute section 0 (staging) FIRST, then run (a)/(b)/COLE in the
-- SAME SSMS window — #affected_records is session-scoped. The expensive
-- xref<->record join runs ONCE in staging; (a)/(b)/COLE then read the small
-- indexed temp table in seconds instead of re-joining the full tables.
-- No schema change required (tempdb only).


/* ===========================================================================
   0. STAGING — run this first. Pre-filters to package_ids with >1 record
      (a single-record package_id can't be cross-county or multi-document),
      then materializes the xref<->record join once. Doing only the JOIN here
      (no COUNT(DISTINCT)) avoids the wide-varchar distinct + tempdb spill that
      made the original full-table query take 22 minutes.
   =========================================================================== */
IF OBJECT_ID('tempdb..#affected_records') IS NOT NULL DROP TABLE #affected_records;

WITH multi_record AS (
    SELECT package_id
    FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY package_id
    HAVING COUNT(*) > 1
)
SELECT
    x.package_id,
    x.RecordID,
    r.CountyID,
    r.originalFileName,
    r.storageFilePath
INTO #affected_records
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN multi_record m                   ON m.package_id = x.package_id
JOIN [CS_Digital].[dbo].[tblRecord] r ON x.RecordID   = r.recordID;

CREATE CLUSTERED INDEX ix_affected_pkg ON #affected_records (package_id);


/* ---------------------------------------------------------------------------
   (a) DIFFERENT PDFs: package_ids whose records point to more than one DIML
       document. originalFileName = {'package_id','dataset_id'} (clerk_load.py);
       package_id is constant within the group, so >1 distinct originalFileName
       => >1 dataset_id => different underlying document.
       PROXY ONLY — confirm in DIML (list_datasets -> root instrument_pdf
       download_url) before treating as definitive.
   --------------------------------------------------------------------------- */
SELECT
    package_id,
    COUNT(DISTINCT originalFileName) AS distinct_documents,
    COUNT(*)                         AS record_count
FROM #affected_records
WHERE originalFileName IS NOT NULL
GROUP BY package_id
HAVING COUNT(DISTINCT originalFileName) > 1
ORDER BY distinct_documents DESC, record_count DESC;


/* ---------------------------------------------------------------------------
   (b) DIFFERENT COUNTY: package_ids whose records span more than one county.
   --------------------------------------------------------------------------- */
SELECT
    package_id,
    COUNT(DISTINCT CountyID) AS county_count,
    COUNT(*)                 AS record_count
FROM #affected_records
GROUP BY package_id
HAVING COUNT(DISTINCT CountyID) > 1
ORDER BY county_count DESC, record_count DESC;


/* ---------------------------------------------------------------------------
   COLE FIXED DATASET: every record behind a package_id flagged by (a) or (b),
   formatted for COLE's Fixed Dataset Selector. Columns match COLE's example CSV
   (required: recordID, countyName, stateAbbreviation, imageLocation;
   leaseID/fileDate/recordNumber optional). imageLocation mirrors COLE's own
   cs_title_and_chd_title_get_records.sql: LOWER(ISNULL(s3FilePath, storageFilePath)).
   Export as CSV, upload one file to:
     s3://land-{dev,prod}/data/courthouse-ocr-legals-extractor/fixed_dataset/hardcoded_input/
   --------------------------------------------------------------------------- */
WITH affected_pkgs AS (
    SELECT package_id
    FROM #affected_records
    GROUP BY package_id
    HAVING COUNT(DISTINCT CountyID) > 1
        OR COUNT(DISTINCT originalFileName) > 1
)
SELECT DISTINCT
    ar.RecordID                                      AS recordID,
    lc.CountyName                                    AS countyName,
    ls.StateAbbreviation                             AS stateAbbreviation,
    LOWER(ISNULL(s.s3FilePath, ar.storageFilePath))  AS imageLocation
FROM #affected_records ar
JOIN affected_pkgs a                                ON a.package_id = ar.package_id
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID  = ar.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates] ls   ON ls.StateID   = lc.StateID
LEFT JOIN [CS_Digital].[dbo].[tblS3Image] s         ON s.recordID   = ar.RecordID
ORDER BY recordID;


/* ---------------------------------------------------------------------------
   DUPLICATE XREF ROWS (data integrity, not a card expect): RecordIDs with >1
   xref row — a record bound to two package_ids. No evidence of producer impact
   (control table advances every county); a defensive concern for pd.merge only.
   Independent of the staging table (covers ALL RecordIDs, not just multi-record
   package_ids) and already local-only — fast as-is.
   --------------------------------------------------------------------------- */
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


/* ---------------------------------------------------------------------------
   SHAPE 2 — package_id PAIRS per duplicate recordID (input for the DIML same-PDF
   check). Each duplicate recordID (>1 xref row) is pivoted to its two package_ids
   side-by-side, with the record's own county/state and originalFileName for
   context. Feed package_id_1 / package_id_2 to DIML and compare the root
   `instrument_pdf` download_url: if equal, it is one PDF re-registered (dedupe
   is safe); if different, it is a real wrong-document case (resolve before
   deleting either row, and add the record to the COLE reprocess set).

   Runs in three narrow steps to avoid the wide-text GROUP BY + tempdb spill
   that made the single-statement version take ~30 min:
     1. #dup    — recordIDs with >1 xref row, materialized once (one aggregate
                  pass over the table instead of re-evaluating it as a CTE).
     2. #pairs  — pivot package_ids over the SMALL dup set only; no joins, the
                  aggregate carries only narrow keys.
     3. context — attach county/state/originalFileName as 1:1 lookups over the
                  ~4,500-row pivot (no aggregation over wide text).
   pkg_count flags any recordID with MORE than two rows (data shows all = 2).
   For just a sample, add TOP (N) to step 3 (optionally ORDER BY NEWID()).
   --------------------------------------------------------------------------- */
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

-- 3. attach context as 1:1 lookups (no aggregation)
--    Save this result set as  shape2_pairs.csv  (with header) — it is the default
--    input for LND-8451_diml_pdf_check.py (in the LND-8451 repo).
SELECT
    p.RecordID,
    p.package_id_1,
    p.package_id_2,
    p.pkg_count,
    lc.CountyName        AS recordCounty,
    ls.StateAbbreviation AS recordState,
    r.originalFileName   AS recordOriginalFileName
FROM #pairs p
-- LEFT JOIN (not INNER): ~1,670 of the 4,500 dup recordIDs have no tblRecord row
-- (orphaned xref rows). They still carry duplicate package_ids and must stay in the
-- export for the DIML check / dedupe; context columns are just NULL for them.
LEFT JOIN [CS_Digital].[dbo].[tblRecord] r          ON r.recordID  = p.RecordID
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID = r.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates] ls   ON ls.StateID  = lc.StateID
ORDER BY p.RecordID;


-- 1. quantify
SELECT COUNT(*) AS pairs_total,
        SUM(CASE WHEN r.recordID IS NULL THEN 1 ELSE 0 END) AS missing_in_tblRecord
FROM #pairs p
LEFT JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = p.RecordID;   -- expect 4500 / 1670

-- 2. orphan vs case/whitespace: take one missing id, probe exact then normalized
SELECT TOP 1 p.RecordID
FROM #pairs p LEFT JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = p.RecordID
WHERE r.recordID IS NULL;   -- copy the value below

SELECT 'exact'      AS probe, COUNT(*) FROM [CS_Digital].[dbo].[tblRecord] WHERE recordID = '<id>'
UNION ALL
SELECT 'normalized', COUNT(*) FROM [CS_Digital].[dbo].[tblRecord] WHERE LOWER(LTRIM(RTRIM(recordID))) = LOWER(LTRIM(RTRIM('<id>')));


/* ===========================================================================
   SHAPE 1 — FLAT RECORDS: many recordIDs → one package_id
   Shared setup + two result sets:

   A) LND-6796_shape1_records.csv  — package_ids with 2+ live records in
      tblRecord (true cross-county / different-doc cases; the actionable set).

   B) LND-6796_shape1_orphans.csv  — xref rows whose RecordID is absent from
      tblRecord; included in the multi_pkg set but dropped by the INNER JOIN.
      Cleanup candidates, not producer- or COLE-relevant.

   Run this entire block in one SSMS window. Steps 1–3 build the shared temp
   tables; the two final SELECTs can then be exported independently.
   =========================================================================== */

-- Step 1a: package_ids with >1 xref row (counts both live and orphaned RecordIDs).
IF OBJECT_ID('tempdb..#s1_multi_pkg') IS NOT NULL DROP TABLE #s1_multi_pkg;
IF OBJECT_ID('tempdb..#s1_base')      IS NOT NULL DROP TABLE #s1_base;
IF OBJECT_ID('tempdb..#s1_stats')     IS NOT NULL DROP TABLE #s1_stats;

SELECT package_id
INTO #s1_multi_pkg
FROM [CS_Digital].[dbo].[tblDimlXref]
GROUP BY package_id
HAVING COUNT(*) > 1;

CREATE CLUSTERED INDEX ix_s1_mpkg ON #s1_multi_pkg (package_id);

-- Step 1b: live records only — RecordID exists in tblRecord.
SELECT
    x.package_id,
    x.RecordID,
    r.CountyID,
    r.originalFileName,
    r.storageFilePath,
    r.fileDate,
    r.recordNumber
INTO #s1_base
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #s1_multi_pkg m                      ON m.package_id = x.package_id
JOIN [CS_Digital].[dbo].[tblRecord] r     ON r.recordID   = x.RecordID;

CREATE CLUSTERED INDEX ix_s1_pkg ON #s1_base (package_id);

-- Step 2: per-package stats from live records only.
SELECT
    package_id,
    COUNT(DISTINCT CountyID)         AS county_count,
    COUNT(DISTINCT originalFileName) AS distinct_documents,
    COUNT(*)                         AS live_record_count
INTO #s1_stats
FROM #s1_base
GROUP BY package_id;

CREATE CLUSTERED INDEX ix_s1_stats ON #s1_stats (package_id);


-- -------------------------------------------------------------------------
-- A) MULTIPLE LIVE RECORDS — true Shape 1 (actionable, COLE candidate set).
--    live_record_count > 1 excludes package_ids where all but one RecordID
--    was orphaned (only one live record = not a cross-county case).
--    Save as LND-6796_shape1_records.csv
-- -------------------------------------------------------------------------
SELECT
    b.package_id,
    b.RecordID,
    lc.CountyName,
    ls.StateAbbreviation,
    b.recordNumber,
    b.fileDate,
    b.originalFileName,
    b.storageFilePath,
    s.county_count,
    s.distinct_documents,
    s.live_record_count
FROM #s1_base b
JOIN #s1_stats s                                  ON s.package_id = b.package_id
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID  = b.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates]   ls ON ls.StateID   = lc.StateID
WHERE s.live_record_count > 1
ORDER BY b.package_id, lc.CountyName, b.RecordID;


-- -------------------------------------------------------------------------
-- B) ORPHAN XREF ROWS — RecordID in tblDimlXref but absent from tblRecord.
--    Not producer- or COLE-relevant; cleanup only.
--    live_record_count = records under the same package_id that DO exist in
--    tblRecord (0 = fully orphaned package_id, 1+ = partially orphaned).
--    Save as LND-6796_shape1_orphans.csv
-- -------------------------------------------------------------------------
SELECT
    x.package_id,
    x.RecordID                        AS orphaned_RecordID,
    ISNULL(s.live_record_count, 0)    AS live_record_count
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #s1_multi_pkg m                  ON m.package_id  = x.package_id
LEFT JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = x.RecordID
LEFT JOIN #s1_stats s                 ON s.package_id  = x.package_id
WHERE r.recordID IS NULL
ORDER BY x.package_id, x.RecordID;