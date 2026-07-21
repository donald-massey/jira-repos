-- 1,257,175 Total
SELECT COUNT(*)
FROM countyScansTitle.dbo.LND_6838_tbllandDescription tld

-- 308,486 Total
SELECT COUNT(*)
FROM countyScansTitle.dbo.LND_6838_tbllandDescription tld
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tld.CountyID = tlc.CountyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tlc.StateID
WHERE tls.StateName IN ('OHIO','OHIO_PLSS','PENNSYLVANIA','WEST VIRGINIA')
GROUP BY tls.StateName



SET XACT_ABORT ON;
BEGIN TRAN;

DELETE tld
FROM countyScansTitle.dbo.LND_6838_tbllandDescription tld
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tld.CountyID = tlc.CountyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tlc.StateID
WHERE tls.StateName IN ('OHIO', 'OHIO_PLSS', 'PENNSYLVANIA', 'WEST VIRGINIA')

SELECT tld.*
FROM countyScansTitle.dbo.LND_6838_tbllandDescription tld
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tld.CountyID = tlc.CountyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tlc.StateID
WHERE tls.StateName IN ('OHIO', 'OHIO_PLSS', 'PENNSYLVANIA', 'WEST VIRGINIA')

-- Rollback the transaction (for testing purposes)
ROLLBACK TRAN;
-- Uncomment the following line to commit the transaction
--COMMIT TRAN;

-- Check transaction count and state
SELECT @@TRANCOUNT, XACT_STATE();
