--Lease
SELECT TOP 1000 r.recordNumber, c.countyName, ls.StateName, *
FROM countyScansTitle.dbo.tblS3Image s
JOIN countyScansTitle.dbo.tblrecord r ON r.recordID = s.recordID
JOIN countyScansTitle.dbo.tbllookupCounties c ON c.countyID = r.countyID
JOIN countyScansTitle.dbo.tbllookupStates ls ON ls.StateID = c.StateID
WHERE 1=1
AND s._ModifiedBy = 'LND-8093' 
AND r.statusID IN (4,10)
AND r.recordIsLease = 1
AND countyName NOT LIKE 'TRAINING_%'
ORDER BY r._ModifiedDateTime

--Courthouse
SELECT TOP 1000 r.recordNumber, c.countyName, ls.StateName, *
FROM countyScansTitle.dbo.tblS3Image s
JOIN countyScansTitle.dbo.tblrecord r ON r.recordID = s.recordID
JOIN countyScansTitle.dbo.tbllookupCounties c ON c.countyID = r.countyID
JOIN countyScansTitle.dbo.tbllookupStates ls ON ls.StateID = c.StateID
WHERE 1=1
AND s._ModifiedBy = 'LND-8093' 
AND r.statusID IN (4,10)
AND r.recordIsCourthouse = 1
AND countyName NOT LIKE 'TRAINING_%'
ORDER BY r._ModifiedDateTime