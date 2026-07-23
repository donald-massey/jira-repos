-- LND-8093 — Diagnose S3 coverage gaps for Lea, NM and Ector, TX
--             Source database: courthouseDirectTitle
--
-- Four questions answered:
--   1. Coverage summary — what exists, what's missing, and why for each county
--   2. storageFilePath breakdown — where the missing files are supposed to live
--   3. Staging table audit — what LND-8093 staged and what's still pending
--   4. Sample missing records — spot-check paths before a targeted rerun

USE courthouseDirectTitle;


-- ============================================================
-- 1. Coverage summary (one row per county)
-- ============================================================
-- Columns:
--   total_records      — everything in tblRecord for the county
--   in_s3              — already has a tblS3Image entry (any _ModifiedBy)
--   uploaded_by_8093   — specifically uploaded by LND-8093
--   path_is_none       — storageFilePath = 'NONE', permanently ineligible
--   eligible_missing   — has a real path but still not in S3 (the gap)
--   pct_covered        — % of records (including NONE-path ones) that are in S3
-- ============================================================
SELECT
    tls.StateAbbreviation                                               AS state,
    tlc.CountyName                                                      AS county,
    COUNT(*)                                                            AS total_records,
    SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)           AS in_s3,
    SUM(CASE WHEN si._ModifiedBy = 'LND-8093' THEN 1 ELSE 0 END)      AS uploaded_by_8093,
    SUM(CASE WHEN tr.storageFilePath = 'NONE' THEN 1 ELSE 0 END)      AS path_is_none,
    SUM(CASE
            WHEN tr.storageFilePath != 'NONE'
             AND si.recordID IS NULL THEN 1
            ELSE 0
        END)                                                            AS eligible_missing,
    CAST(
        100.0 * SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    AS DECIMAL(5,2))                                                    AS pct_covered
FROM dbo.tblRecord tr
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
LEFT JOIN dbo.tblS3Image    si  ON si.recordID  = tr.recordID
WHERE
    (tlc.CountyName = 'Lea'   AND tls.StateAbbreviation = 'NM')
 OR (tlc.CountyName = 'Ector' AND tls.StateAbbreviation = 'TX')
GROUP BY tls.StateAbbreviation, tlc.CountyName
ORDER BY tls.StateAbbreviation, tlc.CountyName;


-- ============================================================
-- 2. storageFilePath breakdown for eligible-but-missing records
-- ============================================================
-- Groups by the first ~80 chars of storageFilePath to surface:
--   - Whether paths point to the expected share (\\aus2-cs-fss01...)
--   - Whether an alternate share or pattern is the culprit
--   - How many files live under each root path
-- ============================================================
SELECT
    tls.StateAbbreviation                                               AS state,
    tlc.CountyName                                                      AS county,
    LEFT(tr.storageFilePath, 80)                                        AS path_prefix,
    COUNT(*)                                                            AS record_count
FROM dbo.tblRecord tr
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
WHERE
    (   (tlc.CountyName = 'Lea'   AND tls.StateAbbreviation = 'NM')
     OR (tlc.CountyName = 'Ector' AND tls.StateAbbreviation = 'TX')
    )
  AND tr.storageFilePath != 'NONE'
  AND NOT EXISTS (SELECT 1 FROM dbo.tblS3Image si WHERE si.recordID = tr.recordID)
GROUP BY tls.StateAbbreviation, tlc.CountyName, LEFT(tr.storageFilePath, 80)
ORDER BY tls.StateAbbreviation, tlc.CountyName, record_count DESC;


-- ============================================================
-- 3a. Staging table audit — LND_8093_STAGE_NM (Lea county rows)
-- ============================================================
-- Check what LND-8093 staged for NM and how much of Lea is still pending.
-- If the staging table doesn't exist yet this will error; run #1 first to
-- confirm the gap size and decide whether to build the stage.
-- ============================================================
SELECT
    'LND_8093_STAGE_NM'                                                AS stage_table,
    COUNT(*)                                                           AS staged_records,
    SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)          AS already_in_s3,
    SUM(CASE WHEN si.recordID IS NULL     THEN 1 ELSE 0 END)          AS still_pending
FROM dbo.LND_8093_STAGE_NM stg
JOIN dbo.tblRecord          tr  ON tr.recordID  = stg.recordID
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
LEFT JOIN dbo.tblS3Image    si  ON si.recordID  = stg.recordID
WHERE tlc.CountyName = 'Lea'
  AND tls.StateAbbreviation = 'NM';


-- ============================================================
-- 3b. Staging table audit — LND_8093_STAGE_TX (Ector county rows)
-- ============================================================
SELECT
    'LND_8093_STAGE_TX'                                                AS stage_table,
    COUNT(*)                                                           AS staged_records,
    SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)          AS already_in_s3,
    SUM(CASE WHEN si.recordID IS NULL     THEN 1 ELSE 0 END)          AS still_pending
FROM dbo.LND_8093_STAGE_TX stg
JOIN dbo.tblRecord          tr  ON tr.recordID  = stg.recordID
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
LEFT JOIN dbo.tblS3Image    si  ON si.recordID  = stg.recordID
WHERE tlc.CountyName = 'Ector'
  AND tls.StateAbbreviation = 'TX';


-- ============================================================
-- 4. Sample missing records (TOP 50 per county)
-- ============================================================
-- Shows full storageFilePath + fileExtension so you can verify
-- whether the network path is reachable and the file actually exists.
-- ============================================================
SELECT TOP 50
    tls.StateAbbreviation   AS state,
    tlc.CountyName           AS county,
    tr.recordID,
    tr.storageFilePath,
    tr.fileExtension,
    tr.storageFilePath + tr.recordID + tr.fileExtension AS full_local_path
FROM dbo.tblRecord tr
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
WHERE tlc.CountyName = 'Lea'
  AND tls.StateAbbreviation = 'NM'
  AND tr.storageFilePath != 'NONE'
  AND NOT EXISTS (SELECT 1 FROM dbo.tblS3Image si WHERE si.recordID = tr.recordID)
ORDER BY tr.recordID;

SELECT TOP 50
    tls.StateAbbreviation   AS state,
    tlc.CountyName           AS county,
    tr.recordID,
    tr.storageFilePath,
    tr.fileExtension,
    tr.storageFilePath + tr.recordID + tr.fileExtension AS full_local_path
FROM dbo.tblRecord tr
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
WHERE tlc.CountyName = 'Ector'
  AND tls.StateAbbreviation = 'TX'
  AND tr.storageFilePath != 'NONE'
  AND NOT EXISTS (SELECT 1 FROM dbo.tblS3Image si WHERE si.recordID = tr.recordID)
ORDER BY tr.recordID;


-- ============================================================
-- 5. Statewide coverage comparison (NM and TX)
-- ============================================================
-- Lets you compare Lea/Ector against the rest of their states
-- to see if these counties are outliers or consistent with the pack.
-- ============================================================
SELECT
    tls.StateAbbreviation                                              AS state,
    tlc.CountyName                                                     AS county,
    COUNT(*)                                                           AS total_records,
    SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)          AS in_s3,
    SUM(CASE WHEN tr.storageFilePath = 'NONE' THEN 1 ELSE 0 END)     AS path_is_none,
    SUM(CASE
            WHEN tr.storageFilePath != 'NONE'
             AND si.recordID IS NULL THEN 1
            ELSE 0
        END)                                                           AS eligible_missing,
    CAST(
        100.0 * SUM(CASE WHEN si.recordID IS NOT NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    AS DECIMAL(5,2))                                                   AS pct_covered
FROM dbo.tblRecord tr
JOIN dbo.tbllookupCounties  tlc ON tlc.CountyID = tr.countyID
JOIN dbo.tbllookupStates    tls ON tls.StateID  = tr.stateID
LEFT JOIN dbo.tblS3Image    si  ON si.recordID  = tr.recordID
WHERE tls.StateAbbreviation IN ('NM', 'TX')
GROUP BY tls.StateAbbreviation, tlc.CountyName
ORDER BY tls.StateAbbreviation, eligible_missing DESC;