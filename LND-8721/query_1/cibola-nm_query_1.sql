-- CST
SELECT *
FROM [AUS2-DTF-PAP01V].[countyScansTitle].[dbo].[tblrecord] r
JOIN [AUS2-DTF-PAP01V].[countyScansTitle].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN CS_Digital.dbo.tblDimlXref d ON d.recordID = r.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = d.package_id
LEFT JOIN CS_Digital.dbo.tblS3Image s ON s.recordID = r.recordID
WHERE c.countyname = 'cibola'
ORDER BY l.package_id


-- CSD
SELECT *
FROM [CS_Digital].[dbo].[tblrecord] r
JOIN [CS_Digital].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN CS_Digital.dbo.tblDimlXref d ON d.recordID = r.recordID
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = d.package_id
LEFT JOIN CS_Digital.dbo.tblS3Image s ON s.recordID = r.recordID
WHERE c.countyname = 'cibola'
ORDER BY l.package_id


