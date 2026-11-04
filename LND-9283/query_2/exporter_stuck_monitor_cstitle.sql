/*
LND-9283 monitoring query, CSTitle server: how close is ch-lease-exporter to stalling on unexportable TOP 500 rows.
READ-ONLY. Only SELECT / SELECT INTO #temp. Run on the CountyScansTitle server.
Counts eligible unexported lease records that fail an exporter inner join (instrument type, grantor, grantee). The exporter's pool is 500 rows, so at 500 stuck rows nothing exports for any county.
Single result row: totalStuck, a breakdown by cause, headroom to 500 and a status. Thresholds: WARN at 250, ALERT at 400. Cleanup stays manual (data entry re-key, or recordIsLease 0 and StatusID 17 run by hand).
Intended for Martin Ilecek's monitoring notebook so the stuck count is tracked going forward.
*/

SET NOCOUNT ON;

DECLARE @PoolSize INT = 500;
DECLARE @WarnAt INT = 250;
DECLARE @AlertAt INT = 400;

IF OBJECT_ID('tempdb..#Stuck') IS NOT NULL DROP TABLE #Stuck;

SELECT R.recordID, R.instrumentTypeID,
       CASE WHEN T.Code IS NULL THEN 1 ELSE 0 END AS noInstType,
       CASE WHEN GR.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantor,
       CASE WHEN GE.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantee
INTO #Stuck
FROM [countyScansTitle].[dbo].[tblrecord] AS R WITH (NOLOCK)
LEFT JOIN [countyScansTitle].[dbo].[tbllookupInstTypes] AS T ON T.Code = R.instrumentTypeID
OUTER APPLY (SELECT TOP 1 1 AS hasRow FROM [countyScansTitle].[dbo].[tblgrantorGrantee] AS G WITH (NOLOCK)
             WHERE G.recordID = CONVERT(VARCHAR(36), R.recordID) AND G.recordType = 'grantor' AND G.IsDeleted = 0) AS GR
OUTER APPLY (SELECT TOP 1 1 AS hasRow FROM [countyScansTitle].[dbo].[tblgrantorGrantee] AS G WITH (NOLOCK)
             WHERE G.recordID = CONVERT(VARCHAR(36), R.recordID) AND G.recordType = 'grantee' AND G.IsDeleted = 0) AS GE
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 16)
  AND NOT EXISTS (SELECT 1 FROM [countyScansTitle].[dbo].[tblexportLog] AS E WITH (NOLOCK) WHERE E.recordID = R.recordID)
  AND R.fileDate >= '2002-01-01'
  AND R.countyID NOT IN (288,291,292,293,295,296,298,300,684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
                         700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,1187)
  AND (T.Code IS NULL OR GR.hasRow IS NULL OR GE.hasRow IS NULL);

SELECT COUNT(*) AS totalStuck,
       SUM(CASE WHEN noInstType = 1 THEN 1 ELSE 0 END) AS noInstrumentType,
       SUM(CASE WHEN noInstType = 0 AND instrumentTypeID NOT IN ('MOGL', 'OGL', 'POGL', 'ROGL', 'OGLAMD', 'OGLEXT') THEN 1 ELSE 0 END) AS nonLeaseType,
       SUM(CASE WHEN noInstType = 0 AND instrumentTypeID IN ('MOGL', 'OGL', 'POGL', 'ROGL', 'OGLAMD', 'OGLEXT') THEN 1 ELSE 0 END) AS leaseTypeMissingParty,
       @PoolSize - COUNT(*) AS headroomTo500,
       CASE WHEN COUNT(*) >= @AlertAt THEN 'ALERT'
            WHEN COUNT(*) >= @WarnAt THEN 'WARN'
            ELSE 'OK' END AS status,
       GETDATE() AS checkedAt
FROM #Stuck;
