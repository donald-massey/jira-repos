/* ============================================================================
   LND-8424 — Level 1 scoping: are the two RecordIDs the SAME instrument?
   MERCED, CA — RecordNumber 2024017111
     90c3e6e1-...  file date 2024-07-20  -> leaseID 5067911 (matched to DIV1)
     c5d14542-...  file date 2024-07-23  -> leaseID NULL   (never imported)

   Level 1 showed these are NOT a Kafka-key collision (only one has a leaseID).
   They are two CSTitle records sharing one RecordNumber, 3 days apart. Decide:
     SAME instrument (duplicate)  -> publish 90c3e6e1 only; c5d14542 needs no re-export.
     DISTINCT instruments         -> c5d14542 is a real Level 1 miss to remediate.

   Compare the record fields, grantors/grantees, land descriptions, and the staged
   image. Matching dates + parties + same image = duplicate. Different image / parties
   = distinct filings. Read-only.

   Server: AUS2-PHX-DSQL01   Database: countyScansTitle

   Join note: some CSTitle recordID columns are string-typed (tblgrantorGrantee),
   and some hold non-GUID values. Joining a uniqueidentifier to them forces a
   string->GUID conversion that errors on bad data. So each join converts the GUID
   side to varchar (T.recordID = CONVERT(VARCHAR(36), rec.recordID)) — the table
   column stays untouched (sargable) and no bad-data conversion happens.
   ============================================================================ */

DECLARE @records TABLE (recordID UNIQUEIDENTIFIER, label VARCHAR(20));
INSERT INTO @records (recordID, label) VALUES
    ('90c3e6e1-263c-4470-92c2-652f03092842', 'A 2024-07-20'),
    ('c5d14542-c2ea-4a4a-8532-0936227ad2ec', 'B 2024-07-23');

/* 1) Core record fields side by side. */
SELECT rec.label,
       LOWER(R.recordID) AS record_id,
       R.recordNumber, R.instrumentTypeID, R.instrumentDate, R.recordDate,
       R.effectiveDate, R.fileDate, R.volume, R.page, R.statusID,
       R.storageFilePath, R.originalFileName, R.fileExtension
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN @records rec ON R.recordID = CONVERT(VARCHAR(36), rec.recordID);

/* 2) Grantors / grantees — same parties => same instrument. */
SELECT rec.label, LOWER(GG.recordID) AS record_id, GG.recordType, GG.gName
FROM [countyScansTitle].[dbo].[tblgrantorGrantee] GG
JOIN @records rec ON GG.recordID = CONVERT(VARCHAR(36), rec.recordID)
ORDER BY rec.label, GG.recordType, GG.gName;

/* 3) Land descriptions (also feeds the Level 2 mapping question). */
SELECT rec.label, L.landDescriptionID, L.section, L.township, L.rangeOrBlock,
       L.survey, L.AbstractName, L.BriefLegal, L.IsDeleted
FROM [countyScansTitle].[dbo].[tblLandDescription] L
JOIN @records rec ON L.recordID = CONVERT(VARCHAR(36), rec.recordID);

/* 4) Staged image — identical s3FilePath / pageCount / fileSizeBytes => same scan. */
SELECT rec.label, s.recordID, s.s3FilePath, s.pageCount, s.fileSizeBytes, s._ModifiedDateTime
FROM [countyScansTitle].[dbo].[tblS3Image] s
JOIN @records rec ON s.recordID = CONVERT(VARCHAR(36), rec.recordID);
