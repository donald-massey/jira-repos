SET XACT_ABORT ON;
BEGIN TRAN;

UPDATE countyScansTitle.dbo.tblrecord
SET statusID = 4
WHERE recordID IN (
    SELECT tr.recordID
    FROM countyScansTitle.dbo.tblrecord tr
    JOIN countyScansTitle.dbo.tblexportlog tel ON tel.recordID = tr.recordID
    WHERE tel.zipName LIKE '%LND-6732%'
      AND DATEADD(HOUR,10.5,KeyedDate) >= '2025-07-01'
      AND outsourceID IN (24,25)
);


SELECT *
FROM countyScansTitle.dbo.tblrecord tr
JOIN countyScansTitle.dbo.tblexportlog tel ON tel.recordID = tr.recordID
WHERE tel.zipName LIKE '%LND-6732%'
    AND DATEADD(HOUR,10.5,KeyedDate) >= '2025-07-01'
    AND outsourceID IN (24,25)


-- Rollback the transaction (for testing purposes)
ROLLBACK TRAN;
-- Uncomment the following line to commit the transaction
--COMMIT TRAN;

-- Check transaction count and state
SELECT @@TRANCOUNT, XACT_STATE();