/* ============================================================================
   LND-8425 — Level 1a (retrofit): record standing + document image location
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Recoverability check by DIRECT IMAGE READ (preferred over the COLE log check
   in query_4 — no AWS creds needed; storageFilePath is a UNC share readable
   from a Windows session). Mirrors _lease-investigation-template query_1/
   doc_image_paths.sql, which the runbook now runs FIRST.

   Pull the on-prem path for the 3 unmapped MIAMI, KS records from query_3, then
   open the PDF and read the document face:
     * legal description present  -> extraction MISSED it -> reprocess candidate
     * no legal description       -> genuine content gap  -> legitimate write-off

   onprem_full_path = storageFilePath + '\' + originalFileName
     (originalFileName is recordID + fileExtension).
   si.s3FilePath NULL -> no image staged; gap is upstream of imaging.
     (ImageFileExists lives on courthouseDirectTitle.dbo.tblRecord, NOT
      countyScansTitle — use the tblS3Image left-join as the staged-image signal.)
   image _ModifiedBy = cs_updates re-staging is a stale-COLE signal.
   Run on the CSTitle server (countyScansTitle).
   ============================================================================ */

SELECT LOWER(R.recordID) AS record_id,
       R.recordNumber,
       R.statusID,
       R.instrumentTypeID,
       R.fileDate,
       R.storageFilePath,
       R.originalFileName,
       R.fileExtension,
       R.storageFilePath + '\' +
         COALESCE(R.originalFileName, CONVERT(VARCHAR(36), R.recordID) + R.fileExtension) AS onprem_full_path,
       si.s3FilePath,
       si.pageCount,
       si.fileSizeBytes,
       si._ModifiedBy       AS image_ModifiedBy,
       si._ModifiedDateTime AS image_ModifiedDateTime
FROM [countyScansTitle].[dbo].[tblRecord] R
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image] si ON si.recordID = R.recordID
WHERE R.recordID IN (
    '68125b82-1ae2-4058-a46f-f3e46709e47b',   -- 2025-03537  LeaseID 5184347  (ticket target)
    '912d5ae6-e1db-11ea-844c-00505681224b',   -- 2020-04048  LeaseID 4709084
    'a36bcf38-88ac-11ea-899b-00505681224b'    -- 2020-00921  LeaseID 4687944
);
