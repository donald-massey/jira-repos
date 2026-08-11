/* ============================================================================
k   LND-8425 — COLE fixed-dataset input rows (DIAGNOSTIC ONLY — not the lease fix)
   Repo: land.courthouse-ocr-legals-extractor

   NOTE: COLE never writes countyScansTitle.dbo.tbllandDescription — its only DB
   output is CS_Digital.cole.tblRecordProcessingLogs (package_id, errorMessage,
   OCRs3Path); extracted legals go to S3 -> CHD courthouse ES plants, a separate
   product from Legal Leases. So this run canNOT populate the lease's land
   description. The real lease fix is MANUAL ABSTRACTING (see CLAUDE.md).
   Use this only to test whether COLE can OCR a legal off these images at all.

   COLE fixed-dataset contract (FixedDatasetSelector):
     * CSV uploaded to  hardcoded_input/  in the COLE bucket.
     * REQUIRED columns, exact casing:
         recordID, countyName, stateAbbreviation, imageLocation
     * imageLocation MUST be the FULL S3 URL of the PDF (s3://bucket/key) — COLE
       url-parses it (single_chunk_ocr_processor._download_pdf ->
       get_bucket_and_prefix_from_full_location). The on-prem storageFilePath UNC
       (query_5) will NOT work here; use tblS3Image.s3FilePath.
     * A null/empty imageLocation => OCR skipped, IIE will not run for that row.

   Export the result of THIS query as CSV (header + 3 rows) and save it as
   query_6/LND-8425-cole-fixed-dataset.csv. Run on the CSTitle server.
   ============================================================================ */

SELECT
    LOWER(CONVERT(VARCHAR(36), R.recordID)) AS recordID,
    C.CountyName                            AS countyName,
    S.stateAbbreviation                     AS stateAbbreviation,
    si.s3FilePath                           AS imageLocation   -- must be full s3://... ; verify scheme
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN      [countyScansTitle].[dbo].[tblLookupCounties] C ON C.CountyID = R.countyID
JOIN      [countyScansTitle].[dbo].[tblLookupStates]   S ON S.StateID  = R.stateID
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image]        si ON si.recordID = R.recordID
WHERE R.recordID IN (
    '68125b82-1ae2-4058-a46f-f3e46709e47b',   -- 2025-03537  LeaseID 5184347  (ticket target)
    '912d5ae6-e1db-11ea-844c-00505681224b',   -- 2020-04048  LeaseID 4709084
    'a36bcf38-88ac-11ea-899b-00505681224b'    -- 2020-00921  LeaseID 4687944
);

/* If imageLocation comes back without the s3:// scheme (e.g. bucket/key only),
   prefix it before writing the CSV:
       's3://' + si.s3FilePath
   Confirm against one known-good COLE input before submitting all three.
   If si.s3FilePath is NULL, the image was never staged to S3 — that is a
   separate upstream gap (imaging), and COLE cannot OCR it until it is staged. */
