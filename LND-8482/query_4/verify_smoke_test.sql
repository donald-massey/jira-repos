-- LND-8482 smoke-test verification
-- Run AFTER:
--   python -m maintenance.repair_from_report artifacts/cleanup_report_commit_20260713T231201Z.csv \
--       --commit --record-id f45ec396-8c41-1847-ba38-3b390dbe94a8
--
-- Candidate: single-page TIF, tx/pecos. Baseline (pre-commit) captured 2026-08-13:
--   tblrecord.fileExtension = '.tif', statusID = 4, storageFilePath ...\PECOS_IMAGES\F45E
--   tblS3Image             = NO ROW (deleted by cleanup) -> exercises the @@ROWCOUNT=0 INSERT branch
--
-- Expected AFTER --commit:
--   tblrecord.fileExtension    -> '.pdf'   (statusID unchanged = 4)
--   tblS3Image row present with s3FilePath ending '.pdf', pageCount = 1,
--   fileSizeBytes = 4629 (converted PDF), _ModifiedBy = 'LND-8093-repair'
--
-- SELECT-only. Also HEAD the S3 object and confirm the two share files
-- (f45ec396-...tif kept + new f45ec396-...pdf) outside SQL.

DECLARE @recordID varchar(36) = 'f45ec396-8c41-1847-ba38-3b390dbe94a8';

-- 1) tblrecord: extension flipped to .pdf, still in scope
SELECT
    recordID,
    fileExtension,
    statusID,
    storageFilePath
FROM [countyScansTitle].[dbo].[tblrecord]
WHERE recordID = @recordID;

-- 2) tblS3Image: row recreated with correct metadata
SELECT
    recordID,
    s3FilePath,
    pageCount,
    fileSizeBytes,
    _ModifiedBy,
    _ModifiedDateTime
FROM [countyScansTitle].[dbo].[tblS3Image]
WHERE recordID = @recordID;

-- 3) Single-row PASS/FAIL roll-up
SELECT
    CASE WHEN r.fileExtension = '.pdf'                 THEN 'PASS' ELSE 'FAIL' END AS ext_is_pdf,
    CASE WHEN r.statusID = 4                           THEN 'PASS' ELSE 'FAIL' END AS status_unchanged,
    CASE WHEN s.recordID IS NOT NULL                  THEN 'PASS' ELSE 'FAIL' END AS s3image_row_present,
    CASE WHEN s.s3FilePath LIKE '%.pdf'               THEN 'PASS' ELSE 'FAIL' END AS s3path_is_pdf,
    CASE WHEN s.pageCount = 1                          THEN 'PASS' ELSE 'FAIL' END AS pagecount_ok,
    CASE WHEN s.fileSizeBytes = 4629                   THEN 'PASS' ELSE 'FAIL' END AS filesize_ok,
    CASE WHEN s._ModifiedBy = 'LND-8093-repair'       THEN 'PASS' ELSE 'FAIL' END AS modifiedby_ok
FROM [countyScansTitle].[dbo].[tblrecord] r
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image] s
       ON s.recordID = r.recordID
WHERE r.recordID = @recordID;
