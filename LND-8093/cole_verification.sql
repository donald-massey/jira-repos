-- CS_Digital
-- Unified: all LND-8093 records with coverage flags for both COLE systems
-- Run from CS_Digital; countyScansTitle accessed via AUS2-DTF-PAP01V linked server

DROP TABLE IF EXISTS #lnd8093;
DROP TABLE IF EXISTS #cstitle_cole;

-- Stage 1: pull LND-8093 records from countyScansTitle (one linked server hit)
SELECT s.recordID, s.s3FilePath, s.pageCount, s._ModifiedDateTime
INTO #lnd8093
FROM [AUS2-DTF-PAP01V].countyScansTitle.dbo.tblS3Image s
WHERE s._ModifiedBy = 'LND-8093';

-- Stage 2: pull matching countyScansTitle COLE records (one linked server hit)
SELECT rp.recordID
INTO #cstitle_cole
FROM [AUS2-DTF-PAP01V].countyScansTitle.cole.tblRecordProcessed rp
WHERE EXISTS (SELECT 1 FROM #lnd8093 t WHERE t.recordID = rp.recordID);

-- Summary (all local after staging)
SELECT
    COUNT(*)                                                                                          AS total_lnd8093,
    SUM(CASE WHEN cst.recordID   IS NOT NULL THEN 1 ELSE 0 END)                                     AS in_cstitle_cole,
    SUM(CASE WHEN csd.package_id IS NOT NULL THEN 1 ELSE 0 END)                                     AS in_csdigital_cole,
    SUM(CASE WHEN cst.recordID   IS NOT NULL OR  csd.package_id IS NOT NULL THEN 1 ELSE 0 END)      AS in_either_cole,
    SUM(CASE WHEN cst.recordID   IS NULL     AND csd.package_id IS NULL     THEN 1 ELSE 0 END)      AS in_neither_cole
FROM #lnd8093 s
LEFT JOIN #cstitle_cole cst                           ON cst.recordID   = s.recordID
LEFT JOIN CS_Digital.dbo.tbldimlxref x                ON x.recordID     = s.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs csd ON csd.package_id = x.package_id;

-- Records in neither COLE system
SELECT s.recordID, s.s3FilePath, s.pageCount, s._ModifiedDateTime
FROM #lnd8093 s
LEFT JOIN #cstitle_cole cst                           ON cst.recordID   = s.recordID
LEFT JOIN CS_Digital.dbo.tbldimlxref x                ON x.recordID     = s.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs csd ON csd.package_id = x.package_id
WHERE cst.recordID   IS NULL
  AND csd.package_id IS NULL;



-- CountyScansTitle
SELECT
    COUNT(*)                                                        AS total_lnd8093,
    SUM(CASE WHEN rp.recordID IS NOT NULL THEN 1 ELSE 0 END)        AS also_in_cole,
    SUM(CASE WHEN rp.recordID IS NULL     THEN 1 ELSE 0 END)        AS not_in_cole
FROM countyScansTitle.dbo.tblS3Image s
LEFT JOIN countyScansTitle.cole.tblRecordProcessed rp ON rp.recordID = s.recordID
WHERE s._ModifiedBy = 'LND-8093';

SELECT s.recordID, s.s3FilePath, s.pageCount, s._ModifiedDateTime
FROM countyScansTitle.dbo.tblS3Image s
WHERE s._ModifiedBy = 'LND-8093'
    AND NOT EXISTS (
        SELECT 1
        FROM countyScansTitle.cole.tblRecordProcessed rp
        WHERE rp.recordID = s.recordID
)