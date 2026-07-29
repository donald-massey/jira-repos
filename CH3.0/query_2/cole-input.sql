-- COLE fixed-dataset input: {COUNTY} ({STATE}) records from CS_Digital
-- Replace {COUNTY} with lowercase county name (e.g. 'cibola')
-- Output feeds the COLE reprocess submission

SELECT
    r.recordID,
    c.countyname      AS countyName,
    s.stateAbbreviation,
    r.storageFilePath AS imageLocation,
    s3.s3FilePath
FROM [CS_Digital].[dbo].[tblrecord] r
JOIN [CS_Digital].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
JOIN [CS_Digital].[dbo].[tbllookupstates] s   ON s.stateID  = r.stateID
JOIN [CS_Digital].[dbo].[tblS3Image] s3       ON s3.recordID = r.recordID
JOIN [CS_Digital].[dbo].[tblDimlXref] d       ON d.recordID = r.recordID
WHERE c.countyname = '{COUNTY}'
