/* ============================================================================
   LND-8424 — full document image paths for the two MERCED records (read-only).
   MERCED, CA — RecordNumber 2024017111.

   On-prem UNC = storageFilePath + '\' + originalFileName
     (matches the producer's image_location: storageFilePath + '\' + recordID + ext;
      originalFileName is recordID + ext).
   S3         = tblS3Image.s3FilePath.

   Server: AUS2-PHX-DSQL01   Database: countyScansTitle
   ============================================================================ */

DECLARE @records TABLE (recordID UNIQUEIDENTIFIER, label VARCHAR(20));
INSERT INTO @records (recordID, label) VALUES
    ('90c3e6e1-263c-4470-92c2-652f03092842', 'A 2024-07-20'),
    ('c5d14542-c2ea-4a4a-8532-0936227ad2ec', 'B 2024-07-23');

SELECT rec.label,
       LOWER(R.recordID) AS record_id,
       R.storageFilePath,
       R.originalFileName,
       R.fileExtension,
       R.storageFilePath + '\' +
         COALESCE(R.originalFileName, CONVERT(VARCHAR(36), R.recordID) + R.fileExtension) AS onprem_full_path,
       si.s3FilePath,
       si.pageCount,
       si.fileSizeBytes
FROM [countyScansTitle].[dbo].[tblRecord] R
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image] si ON si.recordID = R.recordID
JOIN @records rec ON R.recordID = CONVERT(VARCHAR(36), rec.recordID);
