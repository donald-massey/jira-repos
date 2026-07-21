USE countyScansTitle;
SET ANSI_NULLS ON;
SET ANSI_WARNINGS ON;
GO
/****************************************************************************************************************************************************************
** File:            LND-6732_Categorized_Queries_Updated.sql
** Author:          Donald Massey (Updated)
** Copyright:       Enverus
** Creation Date:   2025-03-19
** Description:     Categorized queries for recordID existence in tblexportlog and tblrecord using base query structure
***************************************************************************************************************************************************************
** Date:        Author:             Description:
** --------     --------            -------------------------------------------
** 2025-03-19   Donald Massey       Updated to categorize records based on table presence using specified base query
***************************************************************************************************************************************************************/

-- Create temporary tables to store DIV1 and CountyScansTitle data
IF OBJECT_ID('tempdb..#LND_6732_cst_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_cst_values;

-- Create CST values temp table
SELECT 
    LOWER(tr.recordID) AS recordID,
    tr.recordNumber,
    CONVERT(varchar, tr.fileDate, 23) AS fileDate,
	CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.volume,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.volume,''))
	END AS volume,
	CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.page,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.page,''))
   END AS page,
   c.CountyName AS countyName,
   tr.countyID AS countyID
INTO #LND_6732_cst_values
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.LeasingID = tr.countyID
JOIN countyScansTitle.dbo.tbllookupCounties c ON c.countyID = tr.countyID AND c.stateID = tr.stateID
WHERE tr.recordIsLease = 1
  AND tr.statusID IN (4,16)
  AND tr.fileDate >= '2002-01-01'
	      -- Include EOG McMullen and Gonzales. These are only keyed for EOG so we need to sources leases from those plants.
              and tr.countyID not in (288,291,292,293,295,296,298,300,684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
              700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,1187);
-- 966,634 Dev
-- 985,390 Prod
SELECT COUNT(*) FROM #LND_6732_cst_values;


-- Create DIV1 values temp table
IF OBJECT_ID('tempdb..#LND_6732_div1_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_div1_values;

-- Add joining back to the tbls3image for recordIDs here and then populate them if they don't exist, a CASE statement or coalesce like Chad mentioned should work
SELECT 
    COALESCE(destRanked.leaseid, tll.LeaseID) AS LeaseID,
	COALESCE(destRanked.recordID, LOWER(NEWID())) AS div1_generated_recordid,
	tll.instrument,
    tll.recordNumber,
    CONVERT(varchar, tll.recordDate, 23) AS RecordDate,
	CASE
		WHEN TRY_CONVERT(INT, ISNULL(tll.Vol,'')) = 0
		THEN NULL
		ELSE TRY_CONVERT(INT, ISNULL(tll.Vol,''))
	END AS volume,
	CASE
		WHEN TRY_CONVERT(INT, ISNULL(tll.pg,'')) = 0
		THEN NULL
		ELSE TRY_CONVERT(INT, ISNULL(tll.pg,''))
	END AS page,
    CASE
		WHEN TDF.Filename IS NOT NULL
		THEN CONCAT('\\smb.dc2isilon.na.drillinginfo.com\didocuments\leaseTracts\', tdf.Path, '\', tdf.Filename)
		ELSE NULL
	END AS sourceFilePath,
	tdf.Filename AS originalFileName,
	CASE
		WHEN tdf.Filename LIKE ('%.pdf%')
			THEN '.pdf'
		WHEN tdf.Filename LIKE ('%.jpg%')
			THEN '.jpg'
		WHEN tdf.Filename LIKE ('%.tif%')
			THEN '.tif'
		ELSE NULL
	END AS fileType,
	CASE
		WHEN tdf.Filename LIKE ('%.pdf%')
			THEN '.pdf'
		WHEN tdf.Filename LIKE ('%.jpg%')
			THEN '.jpg'
		WHEN tdf.Filename LIKE ('%.tif%')
			THEN '.tif'
		ELSE NULL
	END AS fileExtension,
    c.CountyName AS CountyName,
	tll.countyID AS countyID,
	c.StateID AS StateID,
	EffectiveDate,
	InstrumentDate,
	acres,
	tll.depthcode,
	depthMin,
	depthMax,
	extensionTermMonths,
	extensionBonus,
	isBlm,
	isState,
	TermMonths,
	ROYALTY,
	DelayRental,
	DelayRentalValue
INTO #LND_6732_div1_values
FROM [linktoDiv1Repl].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY leaseid ORDER BY recordID DESC) AS rn
    FROM countyScansTitle.dbo.LND_6732_DEST_20250717
) destRanked
	ON destRanked.leaseid = tll.LeaseID AND destRanked.rn = 1
LEFT JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.leasingID = tll.CountyID
LEFT JOIN [linktoDiv1Repl].[div1_daily].[dbo].[tblCounty] c ON c.CountyID = tll.CountyID
LEFT JOIN (
    SELECT
        leaseId,
        MAX(updated) AS maxUpdatedDate
    FROM [linktoDiv1Repl].[div1_Daily].[dbo].[tblLegalLeaseDocumentMapping]
    GROUP BY leaseId
) maxdocs 
    ON maxdocs.leaseId = tll.LeaseID
LEFT JOIN [linktoDiv1Repl].[div1_Daily].[dbo].[tblLegalLeaseDocumentMapping] tlldm 
    ON tlldm.leaseId = tll.LeaseID AND tlldm.updated = maxdocs.maxUpdatedDate
LEFT JOIN [linktoDiv1Repl].[div1_Daily].[dbo].[tblDocument] td ON td.DocumentId = tlldm.documentId
LEFT JOIN [linktoDiv1Repl].[div1_Daily].[dbo].[tblDocumentFile] tdf ON tdf.DocumentId = td.DocumentId

-- 4,887,019 Dev
-- 4,936,529 Prod
SELECT COUNT(*) FROM #LND_6732_div1_values


SELECT TOP 10 *
FROM #LND_6732_div1_values
WHERE recordNumber ='5032367'


/*
SET XACT_ABORT ON;
BEGIN TRAN;

-- CATEGORY 1: recordid exists in tblrecord and tblexportlog with NULL LeaseID and DIV1 Match
-- 21,840 records
SELECT DISTINCT
    LOWER(cst.recordID) AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName,
	'Category 1: Exists in countyScansTitle with NULL LeaseID' AS category
FROM countyScansTitle.dbo.tblexportLog tel
JOIN #LND_6732_cst_values cst ON tel.recordID = cst.recordID
JOIN #LND_6732_div1_values div1 ON div1.recordNumber = cst.recordNumber
                               AND div1.RecordDate = cst.fileDate
                               AND div1.CountyName = cst.countyName
WHERE tel.LeaseID IS NULL;

-- Update statement for Category 1 records
UPDATE tel
SET 
    tel.LeaseID = div1.LeaseID,
	tel.zipName = 'LND-6732(1)',
	tel._CreatedBy = 'LND-6732(1)',
    tel._ModifiedDateTime = GETDATE(),
	tel._ModifiedBy = 'LND-6732(1)'
FROM countyScansTitle.dbo.tblexportLog tel
JOIN #LND_6732_cst_values cst ON tel.recordID = cst.recordID
JOIN #LND_6732_div1_values div1 ON div1.recordNumber = cst.recordNumber
                               AND div1.RecordDate = cst.fileDate
                               AND div1.CountyName = cst.countyName
WHERE tel.LeaseID IS NULL AND (_CreatedBy IS NULL AND _ModifiedBy IS NULL);


SELECT COUNT(DISTINCT tel.recordID)
FROM countyScansTitle.dbo.tblexportLog tel
JOIN #LND_6732_cst_values cst ON tel.recordID = cst.recordID
JOIN #LND_6732_div1_values div1 ON div1.recordNumber = cst.recordNumber
                               AND div1.RecordDate = cst.fileDate
                               AND div1.CountyName = cst.countyName
WHERE zipName = 'LND-6732(1)';



-- CATEGORY 2: Records in Div1 that don't have a match in CST
-- 2,118,373 Records
SELECT 
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    tel.leaseID AS tel_leaseID,
	div1.LeaseID AS div1_leaseid,
	div1_generated_recordid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName,
    'Category 2: Exists in Div1 but not in CST' AS category
FROM #LND_6732_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportlog tel ON tel.LeaseID = div1.LeaseID
LEFT JOIN #LND_6732_cst_values cst ON cst.recordNumber = div1.RecordNumber 
							 AND cst.fileDate = div1.RecordDate
							 AND cst.countyName = div1.CountyName
JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.LeasingID = div1.countyID
WHERE tel.LeaseID IS NULL AND mcl.CourthouseTitleID IS NOT NULL;

-- Create New Status In tblStatus
INSERT INTO countyScansTitle.dbo.tblStatus
(statusID, stapleDescription, dataEntryDescription, IncomingInspectionDescription, assignmentDescription)
SELECT
	90,								-- statusID
	NULL,							-- stapleDescription
	'Leases Mapped From DIV1',		-- dataEntryDescription
	'not currently in use',			-- IncomingInspectionDescription
	'not currently in use'			-- assignmentDescription
*/


IF OBJECT_ID('countyScansTitle.dbo.LND_6732_tblrecord', 'U') IS NOT NULL
    DROP TABLE countyScansTitle.dbo.LND_6732_tblrecord;

-- INSERT into tblrecord for Category 2 records
-- Default Value (Gathered from Ryan M Mapping / csdigital-to-cstitle)
SELECT
    div1.div1_generated_recordid AS recordID,				-- recordID, Default Value
    CASE
		WHEN div1.sourceFilePath IS NOT NULL
		THEN div1.sourceFilePath
		ELSE ''
	END AS sourceFilePath,									-- sourceFilePath, DIV1
	'' AS storageFilePath,									-- storageFilePath, TBD
	CASE
		WHEN div1.originalFileName IS NOT NULL
		THEN div1.originalFileName
		ELSE ''
	END AS originalFileName,								-- originalFileName, DIV1
	CASE
		WHEN div1.fileType IS NOT NULL
		THEN div1.fileType
		ELSE ''
	END AS fileType,										-- fileType, DIV1
	CASE
		WHEN div1.fileExtension IS NOT NULL
		THEN div1.fileExtension
		ELSE ''
	END AS fileExtension,									-- fileExtension, DIV1
	0 AS gathererID,										-- gathererID, Default Value
	GETDATE() AS receivedDate,	    						-- receivedDate, Default Value
	17 AS bookTypeID,		     							-- bookTypeID, Default Value
    mcl.courthouseTitleID AS countyID,      				-- countyID, Default Value
	CASE
		WHEN div1.StateID = 1
		THEN 48
		WHEN div1.StateID = 2
		THEN 22
		WHEN div1.StateID = 3
		THEN 55
		WHEN div1.StateID = 4
		THEN 35
		WHEN div1.StateID = 5
		THEN 40
		WHEN div1.StateID = 60
		THEN 1
		WHEN div1.StateID = 62
		THEN 5
		WHEN div1.StateID = 63
		THEN 7
		WHEN div1.StateID = 64
		THEN 8
		WHEN div1.StateID = 66
		THEN 10
		WHEN div1.StateID = 74
		THEN 20
		WHEN div1.StateID = 79
		THEN 26
		WHEN div1.StateID = 81
		THEN 28
		WHEN div1.StateID = 83
		THEN 30
		WHEN div1.StateID = 85
		THEN 32
		WHEN div1.StateID = 90
		THEN 38
		WHEN div1.StateID = 91
		THEN 39
		WHEN div1.StateID = 92
		THEN 41
		WHEN div1.StateID = 93
		THEN 43
		WHEN div1.StateID = 96
		THEN 46
		WHEN div1.StateID = 98
		THEN 49
		WHEN div1.StateID = 101
		THEN 52
		WHEN div1.StateID = 102
		THEN 53
	END AS stateID,											-- stateID, Default Value
	div1.volume AS volume,   								-- Volume, DIV1
    div1.page AS page,										-- Page, DIV1
	0 AS outsourceID,										-- outsourceID, Default Value
	NULL AS outsourcedDate,									-- outsourcedDate, Default Value
	1 AS stapled,											-- stapled, Default Value
    NULL AS stapleInspectorNumber,							-- stapleInspectorNumber, Default Value
    NULL AS stapleQcDate,   								-- stapleQcDate, Default Value
	90 AS statusID,											-- statusID, Default Value
	NULL AS keyerNumber,    								-- keyerNumber, Default Value
    NULL AS reassignedTo,									-- reassignedTo, Default Value
    NULL AS keyedDate,										-- keyedDate, Default Value
    NULL AS modifiedDate,									-- modifiedDate, Default Value
    NULL AS inspectorNumber,								-- inspectorNumber, Default Value
    NULL AS qcDate,											-- qcDate, Default Value
    0 AS manualAccept,										-- manualAccept, Default Value
    0 AS manualReject,										-- manualReject, Default Value
    0 AS qaReserved,										-- qaReserved, Default Value
    0 AS holding,											-- holding, Default Value
    NULL AS keyerComments,									-- keyerComments, Default Value
    NULL AS supervisorComments,     						-- supervisorComments, Default Value
    NULL AS pendingDate,									-- pendingDate, Default Value
    0 AS exported,											-- exported, Default Value
    NULL AS exportDate,  									-- exportDate, Default Value
    div1.RecordDate AS recordDate,							-- recordDate, DIV1
    div1.EffectiveDate AS effectiveDate,					-- effectiveDate, DIV1
	CASE
		WHEN div1.instrument = 0
		THEN 'OGL'
		WHEN div1.instrument = 1
		THEN 'MOGL'
		WHEN div1.instrument = 2
		THEN 'OP'
		WHEN div1.instrument = 3
		THEN 'SOP'
		WHEN div1.instrument = 4
		THEN 'SMEM'
		WHEN div1.instrument = 5
		THEN 'REOGL'
		WHEN div1.instrument = 6
		THEN 'OGL'
		WHEN div1.instrument = 7
		THEN 'OGLEXT'
		WHEN div1.instrument = 8
		THEN 'SPER'
		WHEN div1.instrument = 9
		THEN 'ROGL'
		WHEN div1.instrument = 10
		THEN 'OGLAMD'
		WHEN div1.instrument = 11
		THEN 'ASN'
		WHEN div1.instrument = 12
		THEN 'MD'
		WHEN div1.instrument = 13
		THEN 'RD'
	END AS instrumentTypeID,								-- instrumentTypeID, DIV1
	div1.recordNumber AS recordNumber,   					-- recordNumber, DIV1
    div1.InstrumentDate AS instrumentDate,					-- instrumentDate, DIV1
	div1.RecordDate AS fileDate,							-- fileDate, DIV1
    'LND-6732(2)' AS remarks,								-- remarks, DIV1
    0 AS MultipleLeasesForTract,    						-- MultipleLeasesForTract, Default Value
    CAST(div1.acres AS FLOAT) AS AreaAmount,				-- AreaAmount, DIV1
    CASE
		WHEN div1.acres IS NULL
		THEN -1
		ELSE 0
	END AS AreaNotAvailable,   								-- AreaNotAvailable, DIV1
    0 AS landDescriptionNotAvailable,						-- LandDescriptionNotAvailable, Default Value
	CASE
		WHEN div1.depthcode = 0
		THEN 'All'
		WHEN div1.depthcode = 1
		THEN 'FromTo'
		WHEN div1.depthcode = 2
		THEN 'SurfaceTo'
		WHEN div1.depthcode = 3
		THEN 'DeeperThan'
		WHEN div1.depthcode = 255
		THEN 'No Data'
		ELSE NULL
	END AS DepthsCoveredType,								-- DepthsCoveredType, DIV1
	div1.depthMin AS DepthsCoveredFrom,  					-- DepthsCoveredFrom, DIV1
    div1.depthMax AS DepthsCoveredTo,   					-- DepthsCoveredTo, DIV1
    CASE
		WHEN div1.extensionTermMonths = 0
		THEN 0
		ELSE 1
	END AS Extension,										-- Extension, DIV1
	div1.extensionTermMonths AS ExtensionLength,		   -- ExtensionLength, DIV1
    CASE
        WHEN div1.extensionTermMonths >= 1
        THEN 'Months'
		ELSE NULL
	END AS ExtensionType,									-- ExtensionType, Default Value
    CAST(div1.extensionBonus AS INT) AS ExtensionBonus, 	-- ExtensionBonus, DIV1
    div1.isBlm AS extensionBLM,								-- ExtensionBLM, DIV1
    div1.isState AS ExtensionState,							-- ExtensionState, DIV1
  	CASE
		WHEN TermMonths IS NULL
		THEN NULL
		WHEN TermMonths = 0
		THEN 0
		WHEN TermMonths BETWEEN 12 AND 23
		THEN 1
		WHEN TermMonths BETWEEN 24 AND 35
		THEN 2
		WHEN TermMonths BETWEEN 36 AND 47
		THEN 3
		WHEN TermMonths BETWEEN 48 AND 59
		THEN 4
		WHEN TermMonths BETWEEN 60 AND 71
		THEN 5
		WHEN TermMonths BETWEEN 72 AND 83
		THEN 6
		WHEN TermMonths BETWEEN 84 AND 95
		THEN 7
		WHEN TermMonths BETWEEN 96 AND 107
		THEN 8
		WHEN TermMonths BETWEEN 108 AND 119
		THEN 9
		WHEN TermMonths BETWEEN 120 AND 131
		THEN 10
		WHEN TermMonths BETWEEN 132 AND 143
		THEN 11
		WHEN TermMonths BETWEEN 144 AND 155
		THEN 12
		WHEN TermMonths BETWEEN 156 AND 167
		THEN 13
		WHEN TermMonths BETWEEN 168 AND 179
		THEN 14
		WHEN TermMonths BETWEEN 180 AND 191
		THEN 15
		WHEN TermMonths BETWEEN 192 AND 203
		THEN 16
		WHEN TermMonths BETWEEN 204 AND 215
		THEN 17
		WHEN TermMonths BETWEEN 216 AND 227
		THEN 18
		WHEN TermMonths BETWEEN 228 AND 239
		THEN 19
		WHEN TermMonths BETWEEN 240 AND 251
		THEN 20
		WHEN TermMonths BETWEEN 252 AND 263
		THEN 21
		WHEN TermMonths BETWEEN 264 AND 275
		THEN 22
		WHEN TermMonths BETWEEN 276 AND 287
		THEN 23
		WHEN TermMonths BETWEEN 288 AND 299
		THEN 24
		WHEN TermMonths BETWEEN 300 AND 311
		THEN 25
		WHEN TermMonths BETWEEN 312 AND 323
		THEN 26
		WHEN TermMonths BETWEEN 324 AND 335
		THEN 27
		WHEN TermMonths BETWEEN 336 AND 347
		THEN 28
		WHEN TermMonths BETWEEN 348 AND 359
		THEN 29
		WHEN TermMonths BETWEEN 360 AND 371
		THEN 30
		WHEN TermMonths = 600
		THEN 50
		WHEN TermMonths = 1188
		THEN 99
	ELSE NULL
	END AS TermLength,								-- TermLength, DIV1
	0 AS TermType,									-- TermType, Default Value
    0 AS TermAvailable,								-- TermAvailable, Default Value
    CAST(div1.ROYALTY AS NUMERIC(5,4)) AS RoyaltyAmount,	-- RoyaltyAmount, DIV1
    CAST(div1.DelayRental AS INT) AS DelayRental,	-- DelayRental, DIV1
    CAST(div1.DelayRentalValue AS FLOAT) AS RentalAmount,   -- RentalAmount, DIV1
    NULL AS RentalBonus,							-- RentalBonus, Default Value
    NULL AS DRVolumePage,							-- DRVolumePage, Default Value
    NULL AS DRRecordNumber,							-- DRRecordNumber, Default Value
    0 AS needsRedaction,							-- needsRedaction, Default Value
    NULL AS ExportedToWeb2,  						-- ExportedToWeb2, Default Value
    NULL AS ExportedToWeb2Date,						-- ExportedToWeb2Date, Default Value
    NULL AS ExportedToWeb,							-- ExportedToWeb, Default Value
    NULL AS ExportedToWebDate,						-- ExportedToWebDate, Default Value
    NULL AS FAQDate,								-- FAQDate, Default Value
    NULL AS FAQAnsweredDate,    					-- FAQAnsweredDate, Default Value
    NULL AS FAQAnsweredBy,      					-- FAQAnsweredBy, Default Value
    NULL AS PoorImage,								-- PoorImage, Default Value
    0 AS NoPriorReference,							-- NoPriorReference, Default Value
    NULL AS MIP,    								-- MIP, Default Value
    NULL AS HandWritten,							-- HandWritten, Default Value
    GETDATE() AS _CreatedDateTime,					-- _CreatedDateTime, Default Value
    'NA\donald.massey' AS _CreatedBy,				-- _CreatedBy, Default Value
    GETDATE() AS _ModifiedDateTime,					-- _ModifiedDateTime, Default Value
    'NA\donald.massey' AS _ModifiedBy,				-- _ModifiedBy, Default Value
    NULL AS causeNumber,							-- causeNumber, Default Value
    NULL AS qcBatchID,								-- qcBatchID, Default Value
    NULL AS auditBatchID,							-- auditBatchID, Default Value
    0 AS IsWebDoc,									-- IsWebDoc, Default Value
    NULL AS SiteId,  								-- SiteId, Default Value
    NULL AS Url,									-- Url, Default Value
    1 AS recordIsLease,								-- recordIsLease, Default Value
    0 AS recordIsCourthouse,						-- recordIsCourthouse, Default Value
    0 AS recordIsAssignment,    					-- recordIsAssignment, Default Value
    NULL AS prevQCBID,								-- prevQCBID, Default Value
    NULL AS ParcelNumber,							-- ParcelNumber, Default Value
    NULL AS InstrumentTypeFull,						-- InstrumentTypeFull, Default Value
    NULL AS TotalPages,								-- TotalPages, Default Value
    NULL AS Consideration,							-- Consideration, Default Value
    NULL AS InstrumentTypeFullId    				-- InstrumentTypeFullId, Default Value
INTO countyScansTitle.dbo.LND_6732_tblrecord
FROM #LND_6732_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tel.LeaseID = div1.LeaseID
LEFT JOIN #LND_6732_cst_values cst ON cst.recordNumber = div1.RecordNumber 
							 AND cst.fileDate = div1.RecordDate
							 AND cst.countyName = div1.CountyName
JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.LeasingID = div1.countyID
WHERE tel.LeaseID IS NULL AND mcl.CourthouseTitleID IS NOT NULL;
-- Dev 3,759,967
-- Prod 3,790,005
SELECT COUNT(*) FROM countyScansTitle.dbo.LND_6732_tblrecord


IF OBJECT_ID(N'countyScansTitle.dbo.LND_6732_tblexportLog') IS NOT NULL
	DROP TABLE countyScansTitle.dbo.LND_6732_tblexportLog;

-- Need to fix the recordID join for tblexportlog so it gathers from the div1 temp table and LND_6732_
-- countyScansTitle.dbo.LND_6732_DEST_20250717

-- INSERT into tblexportlog for Category 2 records
-- 2,118,373 Records
SELECT
    div1.div1_generated_recordid AS recordID, -- Populated from tblrecord
    div1.LeaseID AS LeaseID,                  -- DIV1 LeaseID
    GETDATE() AS exportDate,                  -- Current timestamp as exportDate
    0 AS sentToAudit,                         -- sentToAudit, Default Value
    '' AS zipName,							  -- Default Value
	0 AS zipCopied,                           -- zipCopied, Default Value
	0 AS imageCopied,                         -- imageCopied, Default Value
	GETDATE() AS _CreatedDateTime,            -- _CreatedDateTime, Default Value
	'LND-6732(2)' AS _CreatedBy,              -- _ModifiedDateTime, Default Value
    GETDATE() AS _ModifiedDateTime,           -- Status of last attempt, Default Value
    NULL AS _ModifiedBy,				      -- Current timestamp for DateOfLastAttempt, Default Value
    NULL AS StatusOfLastAttempt,			  -- StatusOfLastAttempt, Default Value
	NULL AS DateOfLastAttempt,				  -- DateOfLastAttempt, Default Value
	NULL AS CountOfLastAttempt				  -- Initial count of attempt, Default Value
INTO countyScansTitle.dbo.LND_6732_tblexportLog
FROM #LND_6732_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportlog tel ON tel.LeaseID = div1.LeaseID
JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.LeasingID = div1.countyID
WHERE tel.LeaseID IS NULL AND mcl.CourthouseTitleID IS NOT NULL;



-- Need to add the Trigger DELETE/ADD
-- 1.3hrs In Dev
INSERT INTO countyScansTitle.dbo.tblrecord (recordID, sourceFilePath, storageFilePath, originalFileName, fileType, fileExtension, gathererID, receivedDate, bookTypeID, countyID, stateID, volume, page, outsourceID, outsourcedDate, stapled, stapleInspectorNumber, stapleQcDate, statusID, keyerNumber, reassignedTo, keyedDate, modifiedDate, inspectorNumber, qcDate, manualAccept, manualReject, qaReserved, holding, keyerComments, supervisorComments, pendingDate, exported, exportDate, RecordDate, effectiveDate, instrumentTypeID, recordNumber, instrumentDate, fileDate, remarks, MultipleLeasesForTract, AreaAmount, AreaNotAvailable, LandDescriptionNotAvailable, DepthsCoveredType, DepthsCoveredFrom, DepthsCoveredTo, Extension, ExtensionLength, ExtensionType, ExtensionBonus, ExtensionBLM, ExtensionState, TermLength, TermType, TermAvailable, RoyaltyAmount, DelayRental, RentalAmount, RentalBonus, DRVolumePage, DRRecordNumber, needsRedaction, ExportedToWeb2, ExportedToWeb2Date, ExportedToWeb, ExportedToWebDate, FAQDate, FAQAnsweredDate, FAQAnsweredBy, PoorImage, NoPriorReference, MIP, HandWritten, _CreatedDateTime, _CreatedBy, _ModifiedDateTime, _ModifiedBy, causeNumber, qcBatchID, auditBatchID, IsWebDoc, SiteId, Url, recordIsLease, recordIsCourthouse, recordIsAssignment, prevQCBID, ParcelNumber, InstrumentTypeFull, TotalPages, Consideration, InstrumentTypeFullId)
SELECT recordID, sourceFilePath, storageFilePath, originalFileName, fileType, fileExtension, gathererID, receivedDate, bookTypeID, countyID, stateID, volume, page, outsourceID, outsourcedDate, stapled, stapleInspectorNumber, stapleQcDate, statusID, keyerNumber, reassignedTo, keyedDate, modifiedDate, inspectorNumber, qcDate, manualAccept, manualReject, qaReserved, holding, keyerComments, supervisorComments, pendingDate, exported, exportDate, RecordDate, effectiveDate, instrumentTypeID, recordNumber, instrumentDate, fileDate, remarks, MultipleLeasesForTract, AreaAmount, AreaNotAvailable, LandDescriptionNotAvailable, DepthsCoveredType, DepthsCoveredFrom, DepthsCoveredTo, Extension, ExtensionLength, ExtensionType, ExtensionBonus, ExtensionBLM, ExtensionState, TermLength, TermType, TermAvailable, RoyaltyAmount, DelayRental, RentalAmount, RentalBonus, DRVolumePage, DRRecordNumber, needsRedaction, ExportedToWeb2, ExportedToWeb2Date, ExportedToWeb, ExportedToWebDate, FAQDate, FAQAnsweredDate, FAQAnsweredBy, PoorImage, NoPriorReference, MIP, HandWritten, _CreatedDateTime, _CreatedBy, _ModifiedDateTime, _ModifiedBy, causeNumber, qcBatchID, auditBatchID, IsWebDoc, SiteId, Url, recordIsLease, recordIsCourthouse, recordIsAssignment, prevQCBID, ParcelNumber, InstrumentTypeFull, TotalPages, Consideration, InstrumentTypeFullId
FROM countyScansTitle.dbo.LND_6732_tblrecord

-- Need to add the Trigger DELETE/ADD
-- 10mins In Dev
INSERT INTO countyScansTitle.dbo.tblexportLog (recordID, LeaseID, exportDate, sentToAudit, zipName, zipCopied, imageCopied, _CreatedDateTime, _CreatedBy, _ModifiedDateTime, _ModifiedBy)
SELECT recordID, LeaseID, exportDate, sentToAudit, zipName, zipCopied, imageCopied, _CreatedDateTime, _CreatedBy, _ModifiedDateTime, _ModifiedBy
FROM countyScansTitle.dbo.LND_6732_tblexportLog
