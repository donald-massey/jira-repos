-- DELETE query for tbls3Image 
-- 57 Total Count
SELECT COUNT(*)
FROM countyScansTitle.dbo.tblS3Image
WHERE recordID IN (SELECT recordID FROM countyScansTitle.dbo.tblS3Image_LND7726 WHERE Processed = -1);

SET XACT_ABORT ON;
BEGIN TRAN;

DELETE FROM countyScansTitle.dbo.tblS3Image
WHERE recordID IN (SELECT recordID FROM countyScansTitle.dbo.tblS3Image_LND7726 WHERE Processed = -1);

SELECT @@ROWCOUNT AS rows_updated;

ROLLBACK TRAN;
--COMMIT TRAN;

SELECT @@TRANCOUNT, XACT_STATE();