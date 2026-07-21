SET XACT_ABORT ON;
BEGIN TRAN;

INSERT INTO countyScansTitle.dbo.tblS3Image (recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedDateTime, _ModifiedBy)
SELECT recordID, s3FilePath, pageCount, fileSizeBytes, _ModifiedDateTime, _ModifiedBy
FROM [countyScansTitle].[dbo].[LND_6827_tblS3Image_20251024]

-- Rollback the transaction (for testing purposes)
ROLLBACK TRAN;

-- Check transaction count and state
SELECT @@TRANCOUNT, XACT_STATE();


UPDATE countyScansTitle.dbo.tblDataLoadersPerCounty
SET LastProcessedDateLandLeaseProducer = NULL
WHERE CountyID IN (
SELECT DISTINCT tr.countyID
FROM countyScansTitle.dbo.tblrecord tr
JOIN [countyScansTitle].[dbo].[LND_6827_tblS3Image_20251024] s3 ON s3.recordID = tr.recordID)

SELECT *
FROM countyScansTitle.dbo.tblDataLoadersPerCounty tdlpc
JOIN countyScansTitle.dbo.tbllookupcounties tlc ON tlc.countyID = tdlpc.countyID
WHERE CountyName = 'GAINES'


SELECT *
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.dbo.tbllookupcounties tlc ON tlc.countyID = tr.countyID
WHERE recordNumber = '201800524'

SELECT *
FROM countyScansTitle.dbo.tblS3Image
WHERE recordID = '95d3e390-7975-11e8-9c4d-00505681224b'



SELECT tel.recordID, LOWER(tls.stateAbbreviation) + '/' + LOWER(tlc.countyName) AS state_countyname, tr.storageFilePath, 's3://enverus-courthouse-prod-chd-plants' + '/' + LOWER(tls.stateAbbreviation) + '/' + LOWER(tlc.countyName) + '/' + LEFT(tr.recordID, 4) + '/' + tr.recordID + tr.fileExtension AS s3FilePath,'' AS page_count, '' AS file_size, GETDATE() AS _ModifiedDateTime, 'LND-6827' AS _ModifiedBy, '' AS status
--INTO countyScansTitle.dbo.LND_6827_stage_20251022
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.dbo.tblexportLog tel ON tel.recordID = tr.recordID
JOIN countyScansTitle.dbo.LND_6827_SRC_20251022 src ON src.lease_id = tel.LeaseID
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.countyID = tr.countyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tr.stateID
WHERE tr.recordIsLease = 1
                and tr.statusID IN (4, 16)
                and tr.fileDate >= '2002-01-01'
            -- Include EOG McMullen and Gonzales. These are only keyed for EOG so we need to sources leases from those plants.
                and tr.countyID not in (288,291,292,293,295,296,298,300,684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
                700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,1187)
                and tr.storageFilePath != 'NONE'
ORDER BY tel.leaseID ASC

SELECT *
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.dbo.tblexportLog tel ON tel.recordID = tr.recordID
WHERE tr.recordID = '95d3e390-7975-11e8-9c4d-00505681224b'



SELECT DISTINCT lease_id
FROM [DS9].[pres].[legal_lease]
WHERE 1=1
    AND (image_link IS NOT NULL AND image_link != 'none')
    AND image_link NOT LIKE '%s3://%'

	SELECT *
	FROM countyScansTitle.dbo.LND_6827_SRC_20251022
	WHERE lease_id = '4253972'