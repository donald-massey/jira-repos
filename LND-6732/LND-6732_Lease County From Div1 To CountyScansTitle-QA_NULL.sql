-- 3,761,988 records
SELECT COUNT(*)
SELECT *
FROM [countyScansTitle].[dbo].[tblrecord]
WHERE CONVERT(varchar, receivedDate, 23) = '2025-04-02'
--  AND statusID = 90

-- 3,840,678 records
SELECT COUNT(*)
FROM [countyScansTitle].[dbo].[tblexportLog]
WHERE CONVERT(varchar,  _ModifiedDateTime, 23) = '2025-04-02'


-- Check that LeaseID from DIV1 is present in tblexportlog
-- Check that every recordID in tblexportlog is in tblrecord
-- Check NULL column % in tblrecord for these records
-- Check if these newly updated records have a large % difference in column values from the other data
-- Need to update StateID, didn't account for additions after all counties were included

-- Create temporary table, this is taking forever
IF OBJECT_ID('tempdb..#tll_qa_6732', 'U') IS NOT NULL
    DROP TABLE #tll_qa_6732;

SELECT LeaseID 
INTO #tll_qa_6732
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease]

IF OBJECT_ID('tempdb..#tel_qa_6732', 'U') IS NOT NULL
    DROP TABLE #tel_qa_6732;

SELECT LeaseID 
INTO #tel_qa_6732
FROM [countyScansTitle].[dbo].[tblexportLog]

-- 3,737 records
SELECT LeaseID
FROM #tel_qa_6732
WHERE LeaseID NOT IN (SELECT LeaseID FROM #tll_qa_6732)


-- 79,804 records
-- Maybe we should just remove these, since they should be handled by the DIV1 -> cst mapping, unless we can populate the leaseID some how
SELECT tel.*, tr	.*
FROM countyScansTitle.dbo.tblrecord tr
INNER JOIN countyScansTitle.dbo.tblexportLog tel ON tel.recordID = tr.recordID
WHERE tel.LeaseID IS NOT NULL
AND (zipName NOT LIKE '%lease%' AND zipName != 'LND-5774')
--WHERE CONVERT(varchar, receivedDate, 23) = '2025-04-02'
--  AND statusID = 90


-- Null Count QA
SELECT 
    COUNT([recordID]) AS [recordID_count],
    SUM(CASE WHEN [recordID] IS NULL THEN 1 ELSE 0 END) AS [recordID_null_count],
    
    COUNT([sourceFilePath]) AS [sourceFilePath_count],
    SUM(CASE WHEN [sourceFilePath] IS NULL OR [sourceFilePath] = '' THEN 1 ELSE 0 END) AS [sourceFilePath_null_count],
    
    COUNT([storageFilePath]) AS [storageFilePath_count],
    SUM(CASE WHEN [storageFilePath] IS NULL OR [storageFilePath] = '' THEN 1 ELSE 0 END) AS [storageFilePath_null_count],
    
    COUNT([originalFileName]) AS [originalFileName_count],
    SUM(CASE WHEN [originalFileName] IS NULL OR [originalFileName] = '' THEN 1 ELSE 0 END) AS [originalFileName_null_count],
    
    COUNT([fileType]) AS [fileType_count],
    SUM(CASE WHEN [fileType] IS NULL OR [fileType] = '' THEN 1 ELSE 0 END) AS [fileType_null_count],
    
    COUNT([fileExtension]) AS [fileExtension_count],
    SUM(CASE WHEN [fileExtension] IS NULL OR [fileExtension] = '' THEN 1 ELSE 0 END) AS [fileExtension_null_count],
    
    COUNT([gathererID]) AS [gathererID_count],
    SUM(CASE WHEN [gathererID] IS NULL THEN 1 ELSE 0 END) AS [gathererID_null_count],
    
    COUNT([receivedDate]) AS [receivedDate_count],
    SUM(CASE WHEN [receivedDate] IS NULL THEN 1 ELSE 0 END) AS [receivedDate_null_count],
    
    COUNT([bookTypeID]) AS [bookTypeID_count],
    SUM(CASE WHEN [bookTypeID] IS NULL THEN 1 ELSE 0 END) AS [bookTypeID_null_count],
    
    COUNT([countyID]) AS [countyID_count],
    SUM(CASE WHEN [countyID] IS NULL THEN 1 ELSE 0 END) AS [countyID_null_count],
    
    COUNT([stateID]) AS [stateID_count],
    SUM(CASE WHEN [stateID] IS NULL THEN 1 ELSE 0 END) AS [stateID_null_count],
    
    COUNT([volume]) AS [volume_count],
    SUM(CASE WHEN [volume] IS NULL OR [volume] = '' THEN 1 ELSE 0 END) AS [volume_null_count],
    
    COUNT([page]) AS [page_count],
    SUM(CASE WHEN [page] IS NULL OR [page] = '' THEN 1 ELSE 0 END) AS [page_null_count],
    
    COUNT([outsourceID]) AS [outsourceID_count],
    SUM(CASE WHEN [outsourceID] IS NULL THEN 1 ELSE 0 END) AS [outsourceID_null_count],
    
    COUNT([outsourcedDate]) AS [outsourcedDate_count],
    SUM(CASE WHEN [outsourcedDate] IS NULL THEN 1 ELSE 0 END) AS [outsourcedDate_null_count],
    
    COUNT([stapled]) AS [stapled_count],
    SUM(CASE WHEN [stapled] IS NULL THEN 1 ELSE 0 END) AS [stapled_null_count],
    
    COUNT([stapleInspectorNumber]) AS [stapleInspectorNumber_count],
    SUM(CASE WHEN [stapleInspectorNumber] IS NULL THEN 1 ELSE 0 END) AS [stapleInspectorNumber_null_count],
    
    COUNT([stapleQcDate]) AS [stapleQcDate_count],
    SUM(CASE WHEN [stapleQcDate] IS NULL THEN 1 ELSE 0 END) AS [stapleQcDate_null_count],
    
    COUNT([statusID]) AS [statusID_count],
    SUM(CASE WHEN [statusID] IS NULL THEN 1 ELSE 0 END) AS [statusID_null_count],
    
    COUNT([keyerNumber]) AS [keyerNumber_count],
    SUM(CASE WHEN [keyerNumber] IS NULL THEN 1 ELSE 0 END) AS [keyerNumber_null_count],
    
    COUNT([reassignedTo]) AS [reassignedTo_count],
    SUM(CASE WHEN [reassignedTo] IS NULL THEN 1 ELSE 0 END) AS [reassignedTo_null_count],
    
    COUNT([keyedDate]) AS [keyedDate_count],
    SUM(CASE WHEN [keyedDate] IS NULL THEN 1 ELSE 0 END) AS [keyedDate_null_count],
    
    COUNT([modifiedDate]) AS [modifiedDate_count],
    SUM(CASE WHEN [modifiedDate] IS NULL THEN 1 ELSE 0 END) AS [modifiedDate_null_count],
    
    COUNT([inspectorNumber]) AS [inspectorNumber_count],
    SUM(CASE WHEN [inspectorNumber] IS NULL THEN 1 ELSE 0 END) AS [inspectorNumber_null_count],
    
    COUNT([qcDate]) AS [qcDate_count],
    SUM(CASE WHEN [qcDate] IS NULL THEN 1 ELSE 0 END) AS [qcDate_null_count],
    
    COUNT([manualAccept]) AS [manualAccept_count],
    SUM(CASE WHEN [manualAccept] IS NULL THEN 1 ELSE 0 END) AS [manualAccept_null_count],
    
    COUNT([manualReject]) AS [manualReject_count],
    SUM(CASE WHEN [manualReject] IS NULL THEN 1 ELSE 0 END) AS [manualReject_null_count],
    
    COUNT([qaReserved]) AS [qaReserved_count],
    SUM(CASE WHEN [qaReserved] IS NULL THEN 1 ELSE 0 END) AS [qaReserved_null_count],
    
    COUNT([holding]) AS [holding_count],
    SUM(CASE WHEN [holding] IS NULL THEN 1 ELSE 0 END) AS [holding_null_count],
    
    COUNT([keyerComments]) AS [keyerComments_count],
    SUM(CASE WHEN [keyerComments] IS NULL OR [keyerComments] = '' THEN 1 ELSE 0 END) AS [keyerComments_null_count],
    
    COUNT([supervisorComments]) AS [supervisorComments_count],
    SUM(CASE WHEN [supervisorComments] IS NULL OR [supervisorComments] = '' THEN 1 ELSE 0 END) AS [supervisorComments_null_count],
    
    COUNT([pendingDate]) AS [pendingDate_count],
    SUM(CASE WHEN [pendingDate] IS NULL THEN 1 ELSE 0 END) AS [pendingDate_null_count],
    
    COUNT([exported]) AS [exported_count],
    SUM(CASE WHEN [exported] IS NULL THEN 1 ELSE 0 END) AS [exported_null_count],
    
    COUNT([exportDate]) AS [exportDate_count],
    SUM(CASE WHEN [exportDate] IS NULL THEN 1 ELSE 0 END) AS [exportDate_null_count],
    
    COUNT([RecordDate]) AS [RecordDate_count],
    SUM(CASE WHEN [RecordDate] IS NULL THEN 1 ELSE 0 END) AS [RecordDate_null_count],
    
    COUNT([effectiveDate]) AS [effectiveDate_count],
    SUM(CASE WHEN [effectiveDate] IS NULL THEN 1 ELSE 0 END) AS [effectiveDate_null_count],
    
    COUNT([instrumentTypeID]) AS [instrumentTypeID_count],
    SUM(CASE WHEN [instrumentTypeID] IS NULL THEN 1 ELSE 0 END) AS [instrumentTypeID_null_count],
    
    COUNT([recordNumber]) AS [recordNumber_count],
    SUM(CASE WHEN [recordNumber] IS NULL OR [recordNumber] = '' THEN 1 ELSE 0 END) AS [recordNumber_null_count],
    
    COUNT([instrumentDate]) AS [instrumentDate_count],
    SUM(CASE WHEN [instrumentDate] IS NULL THEN 1 ELSE 0 END) AS [instrumentDate_null_count],
    
    COUNT([fileDate]) AS [fileDate_count],
    SUM(CASE WHEN [fileDate] IS NULL THEN 1 ELSE 0 END) AS [fileDate_null_count],
    
    COUNT([remarks]) AS [remarks_count],
    SUM(CASE WHEN [remarks] IS NULL OR [remarks] = '' THEN 1 ELSE 0 END) AS [remarks_null_count],
    
    COUNT([MultipleLeasesForTract]) AS [MultipleLeasesForTract_count],
    SUM(CASE WHEN [MultipleLeasesForTract] IS NULL THEN 1 ELSE 0 END) AS [MultipleLeasesForTract_null_count],
    
    COUNT([AreaAmount]) AS [AreaAmount_count],
    SUM(CASE WHEN [AreaAmount] IS NULL THEN 1 ELSE 0 END) AS [AreaAmount_null_count],
    
    COUNT([AreaNotAvailable]) AS [AreaNotAvailable_count],
    SUM(CASE WHEN [AreaNotAvailable] IS NULL THEN 1 ELSE 0 END) AS [AreaNotAvailable_null_count],
    
    COUNT([LandDescriptionNotAvailable]) AS [LandDescriptionNotAvailable_count],
    SUM(CASE WHEN [LandDescriptionNotAvailable] IS NULL THEN 1 ELSE 0 END) AS [LandDescriptionNotAvailable_null_count],
    
    COUNT([DepthsCoveredType]) AS [DepthsCoveredType_count],
    SUM(CASE WHEN [DepthsCoveredType] IS NULL THEN 1 ELSE 0 END) AS [DepthsCoveredType_null_count],
    
    COUNT([DepthsCoveredFrom]) AS [DepthsCoveredFrom_count],
    SUM(CASE WHEN [DepthsCoveredFrom] IS NULL THEN 1 ELSE 0 END) AS [DepthsCoveredFrom_null_count],
    
    COUNT([DepthsCoveredTo]) AS [DepthsCoveredTo_count],
    SUM(CASE WHEN [DepthsCoveredTo] IS NULL THEN 1 ELSE 0 END) AS [DepthsCoveredTo_null_count],
    
    COUNT([Extension]) AS [Extension_count],
    SUM(CASE WHEN [Extension] IS NULL THEN 1 ELSE 0 END) AS [Extension_null_count],
    
    COUNT([ExtensionLength]) AS [ExtensionLength_count],
    SUM(CASE WHEN [ExtensionLength] IS NULL OR [ExtensionLength] = '' THEN 1 ELSE 0 END) AS [ExtensionLength_null_count],
    
    COUNT([ExtensionType]) AS [ExtensionType_count],
    SUM(CASE WHEN [ExtensionType] IS NULL THEN 1 ELSE 0 END) AS [ExtensionType_null_count],
    
    COUNT([ExtensionBonus]) AS [ExtensionBonus_count],
    SUM(CASE WHEN [ExtensionBonus] IS NULL OR [ExtensionBonus] = '' THEN 1 ELSE 0 END) AS [ExtensionBonus_null_count],
    
    COUNT([ExtensionBLM]) AS [ExtensionBLM_count],
    SUM(CASE WHEN [ExtensionBLM] IS NULL THEN 1 ELSE 0 END) AS [ExtensionBLM_null_count],
    
    COUNT([ExtensionState]) AS [ExtensionState_count],
    SUM(CASE WHEN [ExtensionState] IS NULL THEN 1 ELSE 0 END) AS [ExtensionState_null_count],
    
    COUNT([TermLength]) AS [TermLength_count],
    SUM(CASE WHEN [TermLength] IS NULL OR [TermLength] = '' THEN 1 ELSE 0 END) AS [TermLength_null_count],
    
    COUNT([TermType]) AS [TermType_count],
    SUM(CASE WHEN [TermType] IS NULL THEN 1 ELSE 0 END) AS [TermType_null_count],
    
    COUNT([TermAvailable]) AS [TermAvailable_count],
    SUM(CASE WHEN [TermAvailable] IS NULL THEN 1 ELSE 0 END) AS [TermAvailable_null_count],
    
    COUNT([RoyaltyAmount]) AS [RoyaltyAmount_count],
    SUM(CASE WHEN [RoyaltyAmount] IS NULL OR [RoyaltyAmount] = '' THEN 1 ELSE 0 END) AS [RoyaltyAmount_null_count],
    
    COUNT([DelayRental]) AS [DelayRental_count],
    SUM(CASE WHEN [DelayRental] IS NULL THEN 1 ELSE 0 END) AS [DelayRental_null_count],
    
    COUNT([RentalAmount]) AS [RentalAmount_count],
    SUM(CASE WHEN [RentalAmount] IS NULL OR [RentalAmount] = '' THEN 1 ELSE 0 END) AS [RentalAmount_null_count],
    
    COUNT([RentalBonus]) AS [RentalBonus_count],
    SUM(CASE WHEN [RentalBonus] IS NULL OR [RentalBonus] = '' THEN 1 ELSE 0 END) AS [RentalBonus_null_count],
    
    COUNT([DRVolumePage]) AS [DRVolumePage_count],
    SUM(CASE WHEN [DRVolumePage] IS NULL OR [DRVolumePage] = '' THEN 1 ELSE 0 END) AS [DRVolumePage_null_count],
    
    COUNT([DRRecordNumber]) AS [DRRecordNumber_count],
    SUM(CASE WHEN [DRRecordNumber] IS NULL OR [DRRecordNumber] = '' THEN 1 ELSE 0 END) AS [DRRecordNumber_null_count],
    
    COUNT([needsRedaction]) AS [needsRedaction_count],
    SUM(CASE WHEN [needsRedaction] IS NULL THEN 1 ELSE 0 END) AS [needsRedaction_null_count],
    
    COUNT([ExportedToWeb2]) AS [ExportedToWeb2_count],
    SUM(CASE WHEN [ExportedToWeb2] IS NULL THEN 1 ELSE 0 END) AS [ExportedToWeb2_null_count],
    
    COUNT([ExportedToWeb2Date]) AS [ExportedToWeb2Date_count],
    SUM(CASE WHEN [ExportedToWeb2Date] IS NULL THEN 1 ELSE 0 END) AS [ExportedToWeb2Date_null_count],
    
    COUNT([ExportedToWeb]) AS [ExportedToWeb_count],
    SUM(CASE WHEN [ExportedToWeb] IS NULL THEN 1 ELSE 0 END) AS [ExportedToWeb_null_count],
    
    COUNT([ExportedToWebDate]) AS [ExportedToWebDate_count],
    SUM(CASE WHEN [ExportedToWebDate] IS NULL THEN 1 ELSE 0 END) AS [ExportedToWebDate_null_count],
    
    COUNT([FAQDate]) AS [FAQDate_count],
    SUM(CASE WHEN [FAQDate] IS NULL THEN 1 ELSE 0 END) AS [FAQDate_null_count],
    
    COUNT([FAQAnsweredDate]) AS [FAQAnsweredDate_count],
    SUM(CASE WHEN [FAQAnsweredDate] IS NULL THEN 1 ELSE 0 END) AS [FAQAnsweredDate_null_count],
    
    COUNT([FAQAnsweredBy]) AS [FAQAnsweredBy_count],
    SUM(CASE WHEN [FAQAnsweredBy] IS NULL OR [FAQAnsweredBy] = '' THEN 1 ELSE 0 END) AS [FAQAnsweredBy_null_count],
    
    COUNT([PoorImage]) AS [PoorImage_count],
    SUM(CASE WHEN [PoorImage] IS NULL THEN 1 ELSE 0 END) AS [PoorImage_null_count],
    
    COUNT([NoPriorReference]) AS [NoPriorReference_count],
    SUM(CASE WHEN [NoPriorReference] IS NULL THEN 1 ELSE 0 END) AS [NoPriorReference_null_count],
    
    COUNT([MIP]) AS [MIP_count],
    SUM(CASE WHEN [MIP] IS NULL THEN 1 ELSE 0 END) AS [MIP_null_count],
    
    COUNT([HandWritten]) AS [HandWritten_count],
    SUM(CASE WHEN [HandWritten] IS NULL THEN 1 ELSE 0 END) AS [HandWritten_null_count],
    
    COUNT([_CreatedDateTime]) AS [_CreatedDateTime_count],
    SUM(CASE WHEN [_CreatedDateTime] IS NULL THEN 1 ELSE 0 END) AS [_CreatedDateTime_null_count],
    
    COUNT([_CreatedBy]) AS [_CreatedBy_count],
    SUM(CASE WHEN [_CreatedBy] IS NULL OR [_CreatedBy] = '' THEN 1 ELSE 0 END) AS [_CreatedBy_null_count],
    
    COUNT([_ModifiedDateTime]) AS [_ModifiedDateTime_count],
    SUM(CASE WHEN [_ModifiedDateTime] IS NULL THEN 1 ELSE 0 END) AS [_ModifiedDateTime_null_count],
    
    COUNT([_ModifiedBy]) AS [_ModifiedBy_count],
    SUM(CASE WHEN [_ModifiedBy] IS NULL OR [_ModifiedBy] = '' THEN 1 ELSE 0 END) AS [_ModifiedBy_null_count],
    
    COUNT([causeNumber]) AS [causeNumber_count],
    SUM(CASE WHEN [causeNumber] IS NULL OR [causeNumber] = '' THEN 1 ELSE 0 END) AS [causeNumber_null_count],
    
    COUNT([qcBatchID]) AS [qcBatchID_count],
    SUM(CASE WHEN [qcBatchID] IS NULL THEN 1 ELSE 0 END) AS [qcBatchID_null_count],
    
    COUNT([auditBatchID]) AS [auditBatchID_count],
    SUM(CASE WHEN [auditBatchID] IS NULL THEN 1 ELSE 0 END) AS [auditBatchID_null_count],
    
    COUNT([IsWebDoc]) AS [IsWebDoc_count],
    SUM(CASE WHEN [IsWebDoc] IS NULL THEN 1 ELSE 0 END) AS [IsWebDoc_null_count],
    
    COUNT([SiteId]) AS [SiteId_count],
    SUM(CASE WHEN [SiteId] IS NULL THEN 1 ELSE 0 END) AS [SiteId_null_count],
    
    COUNT([Url]) AS [Url_count],
    SUM(CASE WHEN [Url] IS NULL OR [Url] = '' THEN 1 ELSE 0 END) AS [Url_null_count],
    
    COUNT([recordIsLease]) AS [recordIsLease_count],
    SUM(CASE WHEN [recordIsLease] IS NULL THEN 1 ELSE 0 END) AS [recordIsLease_null_count],
    
    COUNT([recordIsCourthouse]) AS [recordIsCourthouse_count],
    SUM(CASE WHEN [recordIsCourthouse] IS NULL THEN 1 ELSE 0 END) AS [recordIsCourthouse_null_count],
    
    COUNT([recordIsAssignment]) AS [recordIsAssignment_count],
    SUM(CASE WHEN [recordIsAssignment] IS NULL THEN 1 ELSE 0 END) AS [recordIsAssignment_null_count],
    
    COUNT([prevQCBID]) AS [prevQCBID_count],
    SUM(CASE WHEN [prevQCBID] IS NULL THEN 1 ELSE 0 END) AS [prevQCBID_null_count],
    
    COUNT([ParcelNumber]) AS [ParcelNumber_count],
    SUM(CASE WHEN [ParcelNumber] IS NULL OR [ParcelNumber] = '' THEN 1 ELSE 0 END) AS [ParcelNumber_null_count],
    
    COUNT([InstrumentTypeFull]) AS [InstrumentTypeFull_count],
    SUM(CASE WHEN [InstrumentTypeFull] IS NULL OR [InstrumentTypeFull] = '' THEN 1 ELSE 0 END) AS [InstrumentTypeFull_null_count],
    
    COUNT([TotalPages]) AS [TotalPages_count],
    SUM(CASE WHEN [TotalPages] IS NULL THEN 1 ELSE 0 END) AS [TotalPages_null_count],
    
    COUNT([Consideration]) AS [Consideration_count],
    SUM(CASE WHEN [Consideration] IS NULL OR [Consideration] = '' THEN 1 ELSE 0 END) AS [Consideration_null_count],
    
    COUNT([InstrumentTypeFullId]) AS [InstrumentTypeFullId_count],
    SUM(CASE WHEN [InstrumentTypeFullId] IS NULL THEN 1 ELSE 0 END) AS [InstrumentTypeFullId_null_count]
FROM [countyScansTitle].[dbo].[tblrecord]
WHERE CONVERT(varchar, tr.receivedDate, 23) = '2025-04-07';