/*========================================================================
SQL QA QUERIES - MISSING RECORDS ANALYSIS FOR tblLegalLease
========================================================================*/
-- Records missing from tblexportLog, tblrecord available in tblLegalLease
SELECT 
    ll.updated, ll.*
FROM 
    [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] ll
LEFT JOIN (
    SELECT 
        tel.leaseID 
    FROM 
        countyScansTitle.dbo.tblrecord tr
    JOIN 
        countyScansTitle.dbo.tblexportLog tel 
        ON tr.recordID = tel.recordID
) joined_records
ON ll.leaseID = joined_records.leaseID
WHERE 
    joined_records.leaseID IS NULL
ORDER BY ll.updated ASC;


-- tblrecord Total Count
-- 6,489,039 Records
SELECT 
    COUNT(*) AS tblrecord_count
FROM 
    countyScansTitle.dbo.tblrecord
WHERE InstrumentTypeID IN ('MOGL','OGL','OGLAMD','POGL','OGLEXT','ROGL') 
AND statusID IN (4,10,16,18,90)
AND recordIsLease = 1

-- tblrecord Upate Count
-- 3,750,972 Records
SELECT 
    COUNT(*) AS tblrecord_update_count
FROM 
    countyScansTitle.dbo.tblrecord
WHERE remarks LIKE '%LND-6732%'

-- tblexportLog Total Count
-- 31,568,848 Records
SELECT 
    COUNT(DISTINCT recordID) AS tblexportlog_count
FROM 
    countyScansTitle.dbo.tblrecord

-- tblexportlog Update Count
-- 3,750,972 Records
SELECT 
    COUNT(DISTINCT recordID) AS tblexportlog_count
FROM 
    countyScansTitle.dbo.tblrecord
WHERE remarks LIKE '%LND-6732%'



/*========================================================================
SQL QA QUERIES - MISSING RECORDS ANALYSIS FOR tbllandDescription
========================================================================*/
SELECT 
    ld.recordID AS Missing_RecordID,
    COUNT(*) AS Count_Of_Entries
FROM 
    countyScansTitle.dbo.LND_6838_tbllandDescription ld
LEFT JOIN 
    countyScansTitle.dbo.tblrecord r ON ld.recordID = r.recordID
WHERE 
    r.recordID IS NULL
GROUP BY 
    ld.recordID
ORDER BY 
    Count_Of_Entries DESC;

SELECT 
    COUNT(DISTINCT recordID) AS tbllandDescription_total_count
FROM 
    countyScansTitle.dbo.tbllandDescription;

SELECT 
    COUNT(*) AS LND_6838_tbllandDescription_update_count
FROM 
    countyScansTitle.dbo.LND_6838_tbllandDescription;



/*========================================================================
SQL QA QUERIES - MISSING RECORDS ANALYSIS FOR tblGrantorGrantee
========================================================================*/
SELECT 
    gg.recordID AS Missing_RecordID,
    COUNT(*) AS Count_Of_Entries
FROM 
    countyScansTitle.dbo.LND_6833_tblgrantorGrantee gg
LEFT JOIN 
    countyScansTitle.dbo.tblrecord r ON gg.recordID = r.recordID
WHERE 
    r.recordID IS NULL
GROUP BY 
    gg.recordID
ORDER BY 
    Count_Of_Entries DESC;


-- tblgrantorGrantee Total Records
-- 88,931,200
SELECT COUNT(DISTINCT recordID) AS tblgrantorgrantee_total_count
FROM countyScansTitle.dbo.tblgrantorGrantee

-- LND_6833_tblgrantorGrantee Update Records
-- 3,911,697
SELECT COUNT(*) AS LND_6833_tblgrantorGrantee_update_count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'Grantor'

-- 3,810,407
SELECT COUNT(*) AS LND_6833_tblgrantorGrantee_update_count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'Grantee'



/*========================================================================
SQL QA QUERIES - MISSING RECORDS ANALYSIS FOR tbldeedReferenceVolumePage
========================================================================*/
SELECT 
    drvp.recordID AS Missing_RecordID,
    COUNT(*) AS Count_Of_Entries
FROM 
    countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage drvp
LEFT JOIN 
    countyScansTitle.dbo.tblrecord r ON drvp.recordID = r.recordID
WHERE 
    r.recordID IS NULL
GROUP BY 
    drvp.recordID
ORDER BY 
    Count_Of_Entries DESC;

SELECT 
    COUNT(DISTINCT recordID) AS tbldeedReferenceVolumePage_total_count
FROM 
    countyScansTitle.dbo.tbldeedReferenceVolumePage;

SELECT 
    COUNT(*) AS LND_6836_tbldeedReferenceVolumePage_update_count
FROM 
    countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage;