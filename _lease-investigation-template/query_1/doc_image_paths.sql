/* ============================================================================
   {TICKET} — Level 1a: record standing in countyScansTitle + document image
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   RUN THIS FIRST. Before chasing the pipeline, establish how the record stands in
   the source system and go look at the actual document:
     - record standing: recordNumber, statusID, instrumentType, fileDate
     - image location: on-prem UNC + S3, so you can open the PDF and read the legal
     - image provenance: _ModifiedBy / _ModifiedDateTime (cs_updates re-staging is a
       common signal that COLE's output is stale — see query_3)

   On-prem UNC = storageFilePath + '\' + originalFileName
     (matches the producer's image_location; originalFileName is recordID + ext).
   S3         = tblS3Image.s3FilePath.

   Server: AUS2-PHX-DSQL01   Database: countyScansTitle
   ============================================================================ */

DECLARE @records TABLE (recordID UNIQUEIDENTIFIER);
INSERT INTO @records (recordID) VALUES
    {RECORDID_ROWS}   -- e.g. ('90c3e6e1-...'),('c5d14542-...')
;

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
       si._ModifiedBy      AS image_ModifiedBy,
       si._ModifiedDateTime AS image_ModifiedDateTime
FROM [countyScansTitle].[dbo].[tblRecord] R
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image] si ON si.recordID = R.recordID
JOIN @records rec ON R.recordID = CONVERT(VARCHAR(36), rec.recordID);
