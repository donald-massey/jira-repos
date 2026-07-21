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
IF OBJECT_ID('countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage', 'U') IS NOT NULL
    DROP TABLE countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage;

-- 3,802,980 Records are updated in tblrecord
DECLARE @currentDateTime DATETIME = GETDATE();
SELECT 
    LOWER(tr.recordID) AS recordID,
	NULLIF(LTRIM(RTRIM(tll.deedVol)), 'null') AS drVolume,
	NULLIF(LTRIM(RTRIM(tll.deedPg)), 'null') AS drPage,
	NULL AS drbookType,
	@currentDateTime AS _CreatedDateTime,
	'LND-6836' AS _CreatedBy,
	@currentDateTime AS _ModifiedDateTime,
	'LND-6836' AS _ModifiedBy,
	NULL AS Consideration,
	LOWER(NEWID()) AS priorrefid,
	0 AS IsDeleted
INTO countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage
FROM countyScansTitle.dbo.LND_6732_tblrecord tr
JOIN countyScansTitle.dbo.LND_6732_tblExportLog tel ON tr.recordID = tel.recordID
JOIN [LinktoDiv1Repl].[div1_daily].[dbo].[tblLegalLease] tll ON tel.LeaseID = tll.LeaseID
WHERE tll.deedVol IS NOT NULL AND LTRIM(RTRIM(tll.deedVol)) <> '' AND LTRIM(RTRIM(tll.deedVol)) <> 'null' 
  AND tll.deedPg IS NOT NULL AND LTRIM(RTRIM(tll.deedPg)) <> '' AND LTRIM(RTRIM(tll.deedPg)) <> 'null'


-- Insert New Records Into tbldeedReferenceVolumePage
INSERT INTO [countyScansTitle].[dbo].[tbldeedReferenceVolumePage] (
    [recordID],
    [drVolume],
    [drPage],
    [drbookType],
    [_CreatedDateTime],
    [_CreatedBy],
    [_ModifiedDateTime],
    [_ModifiedBy],
    [Consideration],
    [priorrefid],
    [IsDeleted]
)
SELECT
    src.[recordID],
    src.[drVolume],
    src.[drPage],
    src.[drbookType],
    src.[_CreatedDateTime],
    src.[_CreatedBy],
    src.[_ModifiedDateTime],
    src.[_ModifiedBy],
    src.[Consideration],
    src.[priorrefid],
    src.[IsDeleted]
FROM [countyScansTitle].[dbo].[LND_6836_tbldeedReferenceVolumePage] src;


-- QA Section
-- PriorReference count is lowered because of filtering the EMPTY / NULL records
/*
To debug why the query only returns 1.2 million records instead of the expected 3.8 million records, you can create a query that analyzes each filtering condition (`WHERE`, `INNER JOIN`, etc.) and identifies which step is reducing the record count. The following query will help break down and count records at each stage of filtering:

-- Step 1: Count total records in tblrecord
SELECT COUNT(*) AS TotalRecords_tblrecord
FROM countyScansTitle.dbo.LND_6732_tblrecord;

TotalRecords_tblrecord
3,804,368

-- Step 2: Count records after applying INNER JOIN with tblExportLog
SELECT COUNT(DISTINCT tr.recordID) AS Records_After_Join_tblExportLog
FROM countyScansTitle.dbo.LND_6732_tblrecord tr
INNER JOIN countyScansTitle.dbo.LND_6732_tblExportLog tel ON tr.recordID = tel.recordID;

Records_After_Join_tblExportLog
3,755,058

-- Step 3: Count records after JOIN with tblLegalLease
SELECT COUNT(DISTINCT tr.recordID) AS Records_After_Join_tblLegalLease
FROM countyScansTitle.dbo.LND_6732_tblrecord tr
JOIN countyScansTitle.dbo.LND_6732_tblExportLog tel ON tr.recordID = tel.recordID
JOIN [LinktoDiv1Repl].[div1_daily].[dbo].[tblLegalLease] tll ON tel.LeaseID = tll.LeaseID;

Records_After_Join_tblLegalLease
3,755,058

-- Step 4: Count records where deedVol and deedPg are not NULL or empty
SELECT COUNT(DISTINCT tr.recordID) AS Records_With_Valid_DeedVol_DeedPg
FROM countyScansTitle.dbo.LND_6732_tblrecord tr
JOIN countyScansTitle.dbo.LND_6732_tblExportLog tel ON tr.recordID = tel.recordID
JOIN [LinktoDiv1Repl].[div1_daily].[dbo].[tblLegalLease] tll ON tel.LeaseID = tll.LeaseID
WHERE tll.deedVol IS NOT NULL AND tll.deedVol != '' AND tll.deedPg IS NOT NULL AND tll.deedPg != '';

Records_With_Valid_DeedVol_DeedPg
1,285,712

---
Explanation of Each Step:
1. **Step 1: Total Records in `tblrecord`**:
   - Counts all records in the `tblrecord` table to establish the starting point.

2. **Step 2: After `INNER JOIN` with `tblExportLog`**:
   - Counts records that remain after joining `tblrecord` with `tblExportLog` using the `recordID`.

3. **Step 3: After `INNER JOIN` with `tblLegalLease`**:
   - Counts records that remain after joining with `tblLegalLease` using `LeaseID`.

4. **Step 4: Filtering by `deedVol` and `deedPg`**:
   - Applies the filter for `deedVol` and `deedPg` being non-NULL and non-empty.
---

### Analysis:
- Run these queries separately and compare the record counts at each step.
- Identify where the record count drops significantly and focus on that step.
- Common issues include:
  1. **Join conditions**:
     - Some `recordID` or `LeaseID` values may not exist in the joined tables, causing records to be excluded.
  2. **Filters**:
     - The conditions for `deedVol`, `deedPg`, or `receivedDate` may be too restrictive.
  3. **Date Format**:
     - The date filter `CONVERT(varchar, tr.receivedDate, 23)` may not be matching all records correctly. Verify that the format is correct and no records are being unintentionally excluded.

---

### Next Steps:
- Once you've identified the problematic step, refine the query or adjust the data/filters accordingly.
- Let me know if you need further assistance analyzing a specific step or refining the query!
*/

-- Normal NULL count percents
/*
SELECT 
    COUNT(CASE WHEN recordID IS NULL THEN 1 ELSE NULL END) AS recordID_Null_Count,
    COUNT(CASE WHEN recordID IS NOT NULL THEN 1 ELSE NULL END) AS recordID_NotNull_Count,

    COUNT(CASE WHEN drVolume IS NULL THEN 1 ELSE NULL END) AS drVolume_Null_Count,
    COUNT(CASE WHEN drVolume IS NOT NULL THEN 1 ELSE NULL END) AS drVolume_NotNull_Count,

    COUNT(CASE WHEN sani_drVolume IS NULL THEN 1 ELSE NULL END) AS sani_drVolume_Null_Count,
    COUNT(CASE WHEN sani_drVolume IS NOT NULL THEN 1 ELSE NULL END) AS sani_drVolume_NotNull_Count,

    COUNT(CASE WHEN drPage IS NULL THEN 1 ELSE NULL END) AS drPage_Null_Count,
    COUNT(CASE WHEN drPage IS NOT NULL THEN 1 ELSE NULL END) AS drPage_NotNull_Count,

    COUNT(CASE WHEN sani_deedPg IS NULL THEN 1 ELSE NULL END) AS sani_deedPg_Null_Count,
    COUNT(CASE WHEN sani_deedPg IS NOT NULL THEN 1 ELSE NULL END) AS sani_deedPg_NotNull_Count,

    COUNT(CASE WHEN drbookType IS NULL THEN 1 ELSE NULL END) AS drbookType_Null_Count,
    COUNT(CASE WHEN drbookType IS NOT NULL THEN 1 ELSE NULL END) AS drbookType_NotNull_Count,

    COUNT(CASE WHEN _CreatedDateTime IS NULL THEN 1 ELSE NULL END) AS CreatedDateTime_Null_Count,
    COUNT(CASE WHEN _CreatedDateTime IS NOT NULL THEN 1 ELSE NULL END) AS CreatedDateTime_NotNull_Count,

    COUNT(CASE WHEN _CreatedBy IS NULL THEN 1 ELSE NULL END) AS CreatedBy_Null_Count,
    COUNT(CASE WHEN _CreatedBy IS NOT NULL THEN 1 ELSE NULL END) AS CreatedBy_NotNull_Count,

    COUNT(CASE WHEN _ModifiedDateTime IS NULL THEN 1 ELSE NULL END) AS ModifiedDateTime_Null_Count,
    COUNT(CASE WHEN _ModifiedDateTime IS NOT NULL THEN 1 ELSE NULL END) AS ModifiedDateTime_NotNull_Count,

    COUNT(CASE WHEN Consideration IS NULL THEN 1 ELSE NULL END) AS Consideration_Null_Count,
    COUNT(CASE WHEN Consideration IS NOT NULL THEN 1 ELSE NULL END) AS Consideration_NotNull_Count,

    COUNT(CASE WHEN priorrefid IS NULL THEN 1 ELSE NULL END) AS priorrefid_Null_Count,
    COUNT(CASE WHEN priorrefid IS NOT NULL THEN 1 ELSE NULL END) AS priorrefid_NotNull_Count,

    COUNT(CASE WHEN IsDeleted IS NULL THEN 1 ELSE NULL END) AS IsDeleted_Null_Count,
    COUNT(CASE WHEN IsDeleted IS NOT NULL THEN 1 ELSE NULL END) AS IsDeleted_NotNull_Count
FROM countyScansTitle.dbo.LND_6836_tbldeedReferenceVolumePage;
*/
