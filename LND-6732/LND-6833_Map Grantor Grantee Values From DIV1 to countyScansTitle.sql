USE countyScansTitle;
SET ANSI_NULLS ON;
SET ANSI_WARNINGS ON;
GO
/****************************************************************************************************************************************************************
** File:            LND-6833_Map Grantor Grantee Values From DIV1 to countyScansTitle.sql
** Author:          Donald Massey (Updated)
** Copyright:       Enverus
** Creation Date:   2025-04-02
** Description:     Map Grantor Grantee Values From DIV1 to countyScansTitle
***************************************************************************************************************************************************************
** Date:        Author:             Description:
** --------     --------            -------------------------------------------
** 2025-03-19   Donald Massey       Map Grantor Grantee Values From DIV1 to countyScansTitle
***************************************************************************************************************************************************************/

SET XACT_ABORT ON;
BEGIN TRAN;

IF OBJECT_ID('tempdb.dbo.#TempLegalLease', 'U') IS NOT NULL
    DROP TABLE tempdb.dbo.#TempLegalLease;

SELECT *
INTO #TempLegalLease
FROM [LinktoDiv1Repl].[div1_daily].[dbo].[tblLegalLease];

--CREATE INDEX IX_TempLegalLease_LeaseID ON #TempLegalLease(LeaseID);

IF OBJECT_ID('tempdb.dbo.#TempLeaseGrantor', 'U') IS NOT NULL
    DROP TABLE tempdb.dbo.#TempLeaseGrantor

SELECT *
INTO #TempLeaseGrantor
FROM [LinktoDiv1Repl].[div1_daily].[dbo].[tblLeaseGrantor]
WHERE GrantorNAME != '';

--CREATE INDEX IX_TempLeaseGrantor_GrantorID ON #TempLeaseGrantor(GrantorID);

IF OBJECT_ID('tempdb.dbo.#TempLeaseGrantee', 'U') IS NOT NULL
    DROP TABLE tempdb.dbo.#TempLeaseGrantee

SELECT *
INTO #TempLeaseGrantee
FROM [LinktoDiv1Repl].[div1_daily].[dbo].[tblLeaseGrantee]
WHERE GranteeNAME != '';

--CREATE INDEX IX_TempLeaseGrantee_GranteeID ON #TempLeaseGrantee(GranteeID);


IF OBJECT_ID('countyScansTitle.dbo.LND_6833_tblgrantorGrantee', 'U') IS NOT NULL
    DROP TABLE countyScansTitle.dbo.LND_6833_tblgrantorGrantee;

DECLARE @currentDateTime DATETIME = GETDATE();
WITH GrantorData AS (
	SELECT 
		tr.recordID,
		'grantor' AS recordType,
		NULLIF(tlg.GrantorNAME, '') AS gName,
		NULLIF(tlg.ADDRESS, '') AS gAddress,
		NULLIF(tlg.ZIP, '') AS gZip,
		NULLIF(tlg.CITY, '') AS gCity,
		tls.StateID AS StateID,
		@currentDateTime AS _CreatedDateTime,
		'donald-massey' AS _CreatedBy,
		@currentDateTime AS _ModifiedDateTime,
		'donald-massey' AS _ModifiedBy,
		NULL AS interestAssigned,
		0 AS IsDeleted
	FROM #TempLeaseGrantor tlg
	JOIN #TempLegalLease tll ON tll.GrantorID = tlg.GrantorID
	JOIN countyScansTitle.dbo.LND_6732_tblexportLog tel ON tel.LeaseID = tll.LeaseID
	JOIN countyScansTitle.dbo.LND_6732_tblrecord tr ON tr.recordID = tel.recordID
	JOIN countyScansTitle.dbo.tbllookupStates tls ON tlg.STATE = tls.StateAbbreviation
),
-- 3,810,407 Records
GranteeData AS (
	SELECT 
		tr.recordID,
		'grantee' AS recordType,
		NULLIF(tee.GranteeNAME, '') AS gName,
		NULLIF(tee.ADDRESS, '') AS gAddress,
		NULLIF(tee.ZIP, '') AS gZip,
		NULLIF(tee.CITY, '') AS gCity,
		tls.StateID AS StateID,
		@currentDateTime AS _CreatedDateTime,
		'donald-massey' AS _CreatedBy,
		@currentDateTime AS _ModifiedDateTime,
		'donald-massey' AS _ModifiedBy,
		NULL AS interestAssigned,
		0 AS IsDeleted
	FROM #TempLeaseGrantee tee
	JOIN #TempLegalLease tll ON tee.GranteeID = tll.GranteeID
	JOIN countyScansTitle.dbo.LND_6732_tblexportLog tel ON tel.LeaseID = tll.LeaseID
	JOIN countyScansTitle.dbo.LND_6732_tblrecord tr ON tr.recordID = tel.recordID
	JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateAbbreviation = tee.STATE)
SELECT *
INTO countyScansTitle.dbo.LND_6833_tblgrantorGrantee_test
FROM GrantorData
UNION
SELECT * FROM GranteeData;

-- Rollback the transaction (for testing purposes)
--ROLLBACK TRAN;
-- Uncomment the following line to commit the transaction
COMMIT TRAN;

-- Check transaction count and state
SELECT @@TRANCOUNT, XACT_STATE();

SELECT *
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee

-- Insert New Records Into tblgrantorGrantee, 1hr 8mins
INSERT INTO [countyScansTitle].[dbo].[tblgrantorGrantee] (
    [recordID],
    [recordType],
    [gName],
    [gAddress],
    [gZip],
    [gCity],
    [StateID],
    [_CreatedDateTime],
    [_CreatedBy],
    [_ModifiedDateTime],
    [_ModifiedBy],
    [interestAssigned],
    [IsDeleted]
)
SELECT
    [recordID],
    [recordType],
    [gName],
    [gAddress],
    [gZip],
    [gCity],
    [StateID],
    [_CreatedDateTime],
    [_CreatedBy],
    [_ModifiedDateTime],
    [_ModifiedBy],
    [interestAssigned],
    [IsDeleted]
FROM [countyScansTitle].[dbo].[LND_6833_tblgrantorGrantee]


-- QA Section
-- tblRecord Total Records: 3,750,972
SELECT COUNT(*) AS tblrecord_count
FROM countyScansTitle.dbo.LND_6732_tblrecord

-- GrantorData Total Records: 3,911,697
-- Grantor Updates: 3,911,697
SELECT COUNT(DISTINCT recordID) AS grantor_count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'grantor'

-- GranteeData Total Records: 3,810,407
-- Grantee Updates: 3,810,407
SELECT COUNT(DISTINCT recordID) AS grantee_count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'grantee'

/*========================================================================
SQL QA QUERY - VERIFY gName COVERAGE IN tblLeaseGrantor/tblLeaseGrantee
========================================================================
Purpose: Identify gNames from LND_6833_tblgrantorGrantee that do NOT exist
         in tblLeaseGrantor (GrantorName) or tblLeaseGrantee (GranteeName).
Created: 2025-06-17
Author: donald-massey
========================================================================*/

-- Subquery for all valid Grantor/Grantee names
WITH ValidNames AS (
    SELECT DISTINCT GrantorName AS gName
    FROM [LinktoDiv1Repl].[div1_daily].[dbo].[tblLeaseGrantor]
    WHERE GrantorName != ''
    UNION
    SELECT DISTINCT GranteeName AS gName
    FROM [LinktoDiv1Repl].[div1_daily].[dbo].[tblLeaseGrantee]
    WHERE GranteeName != ''
)
-- Find gNames in source that are missing from ValidNames
SELECT
    ggg.gName,
    COUNT(*) AS Occurrences
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee ggg
LEFT JOIN ValidNames vn ON ggg.gName = vn.gName
WHERE vn.gName IS NULL
GROUP BY ggg.gName
ORDER BY Occurrences DESC, ggg.gName;

-- NULL Counts
SELECT 
    SUM(CASE WHEN recordID IS NULL THEN 1 ELSE 0 END) AS recordID_Null_Count,
    SUM(CASE WHEN recordID IS NOT NULL THEN 1 ELSE 0 END) AS recordID_NotNull_Count,
	SUM(CASE WHEN recordType IS NULL THEN 1 ELSE 0 END) AS recordType_Null_Count,
    SUM(CASE WHEN recordType IS NOT NULL THEN 1 ELSE 0 END) AS recordType_NotNull_Count,
    SUM(CASE WHEN gName IS NULL THEN 1 ELSE 0 END) AS gName_Null_Count,
    SUM(CASE WHEN gName IS NOT NULL THEN 1 ELSE 0 END) AS gName_NotNull_Count,
    SUM(CASE WHEN gAddress IS NULL THEN 1 ELSE 0 END) AS gAddress_Null_Count,
    SUM(CASE WHEN gAddress IS NOT NULL THEN 1 ELSE 0 END) AS gAddress_NotNull_Count,
    SUM(CASE WHEN gZip IS NULL THEN 1 ELSE 0 END) AS gZip_Null_Count,
    SUM(CASE WHEN gZip IS NOT NULL THEN 1 ELSE 0 END) AS gZip_NotNull_Count,
    SUM(CASE WHEN gCity IS NULL THEN 1 ELSE 0 END) AS gCity_Null_Count,
    SUM(CASE WHEN gCity IS NOT NULL THEN 1 ELSE 0 END) AS gCity_NotNull_Count,
    SUM(CASE WHEN StateID IS NULL THEN 1 ELSE 0 END) AS StateID_Null_Count,
    SUM(CASE WHEN StateID IS NOT NULL THEN 1 ELSE 0 END) AS StateID_NotNull_Count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'grantor'


SELECT 
    SUM(CASE WHEN recordID IS NULL THEN 1 ELSE 0 END) AS recordID_Null_Count,
    SUM(CASE WHEN recordID IS NOT NULL THEN 1 ELSE 0 END) AS recordID_NotNull_Count,
	SUM(CASE WHEN recordType IS NULL THEN 1 ELSE 0 END) AS recordType_Null_Count,
    SUM(CASE WHEN recordType IS NOT NULL THEN 1 ELSE 0 END) AS recordType_NotNull_Count,
    SUM(CASE WHEN gName IS NULL THEN 1 ELSE 0 END) AS gName_Null_Count,
    SUM(CASE WHEN gName IS NOT NULL THEN 1 ELSE 0 END) AS gName_NotNull_Count,
    SUM(CASE WHEN gAddress IS NULL THEN 1 ELSE 0 END) AS gAddress_Null_Count,
    SUM(CASE WHEN gAddress IS NOT NULL THEN 1 ELSE 0 END) AS gAddress_NotNull_Count,
    SUM(CASE WHEN gZip IS NULL THEN 1 ELSE 0 END) AS gZip_Null_Count,
    SUM(CASE WHEN gZip IS NOT NULL THEN 1 ELSE 0 END) AS gZip_NotNull_Count,
    SUM(CASE WHEN gCity IS NULL THEN 1 ELSE 0 END) AS gCity_Null_Count,
    SUM(CASE WHEN gCity IS NOT NULL THEN 1 ELSE 0 END) AS gCity_NotNull_Count,
    SUM(CASE WHEN StateID IS NULL THEN 1 ELSE 0 END) AS StateID_Null_Count,
    SUM(CASE WHEN StateID IS NOT NULL THEN 1 ELSE 0 END) AS StateID_NotNull_Count
FROM countyScansTitle.dbo.LND_6833_tblgrantorGrantee
WHERE recordType = 'grantee';