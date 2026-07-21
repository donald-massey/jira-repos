-- UPDATE tblrecord with imageFileExists = 0
-- 25,846 Total Count
SELECT COUNT(*)
FROM CS_Digital.dbo.tblrecord tr
WHERE tr.recordID IN (SELECT recordID FROM CS_Digital.dbo.tblS3Image_LND7726 WHERE Processed = -1)
AND tr.ImageFileExists = 1;

SET XACT_ABORT ON;
BEGIN TRAN;

UPDATE tr
SET tr.ImageFileExists = 0
FROM CS_Digital.dbo.tblrecord tr
WHERE tr.recordID IN (SELECT recordID FROM CS_Digital.dbo.tblS3Image_LND7726 WHERE Processed = -1);

SELECT @@ROWCOUNT AS rows_updated;

ROLLBACK TRAN;
--COMMIT TRAN;

SELECT @@TRANCOUNT, XACT_STATE();


-- DELETE query for tbls3Image 
SELECT COUNT(*)
FROM CS_Digital.dbo.tblS3Image
WHERE recordID IN (SELECT recordID FROM CS_Digital.dbo.tblS3Image_LND7726 WHERE Processed = -1);

SET XACT_ABORT ON;
BEGIN TRAN;

DELETE FROM CS_Digital.dbo.tblS3Image
WHERE recordID IN (SELECT recordID FROM CS_Digital.dbo.tblS3Image_LND7726 WHERE Processed = -1);

SELECT @@ROWCOUNT AS rows_updated;

ROLLBACK TRAN;
--COMMIT TRAN;

SELECT @@TRANCOUNT, XACT_STATE();