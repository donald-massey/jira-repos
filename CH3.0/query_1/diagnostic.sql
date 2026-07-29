-- CH3.0 county diagnostic — CST + CSD side-by-side
-- Replace {COUNTY} with lowercase county name (e.g. 'cibola')
-- Run on: AUS2-DTF-PAP01V (CS_Digital accessible as linked server)


-- CST (countyScansTitle) — keyed records
SELECT *
FROM [AUS2-DTF-PAP01V].[countyScansTitle].[dbo].[tblrecord] r
JOIN [AUS2-DTF-PAP01V].[countyScansTitle].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN CS_Digital.dbo.tblDimlXref d ON d.recordID = r.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = d.package_id
LEFT JOIN CS_Digital.dbo.tblS3Image s ON s.recordID = r.recordID
WHERE c.countyname = '{COUNTY}'
ORDER BY l.package_id


-- CSD (CS_Digital) — nonkeyed/historical records
SELECT *
FROM [CS_Digital].[dbo].[tblrecord] r
JOIN [CS_Digital].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN CS_Digital.dbo.tblDimlXref d ON d.recordID = r.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = d.package_id
LEFT JOIN CS_Digital.dbo.tblS3Image s ON s.recordID = r.recordID
WHERE c.countyname = '{COUNTY}'
ORDER BY l.package_id
