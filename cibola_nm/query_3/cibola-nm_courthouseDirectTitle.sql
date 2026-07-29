-- CHDT (courthouseDirectTitle) — same diagnostic as query_1 CST/CSD blocks
-- tblrecord/tbllookupcounties from courthouseDirectTitle; DIML/COLE/S3 xrefs from CS_Digital
SELECT *
FROM [courthouseDirectTitle].[dbo].[tblrecord] r
JOIN [courthouseDirectTitle].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN [courthouseDirectTitle].[cole].tblRecordProcessed p ON p.recordID = r.recordID
LEFT JOIN [courthouseDirectTitle].[dbo].[tblS3Image] s ON s.recordID = r.recordID
WHERE c.countyname = 'cibola'
ORDER BY l.package_id
