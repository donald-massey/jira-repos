/*
LND-9283 diagnostic, CSTitle server: records flagged recordIsLease = 1 whose instrument type is not an oil and gas lease type.
READ-ONLY. Only SELECT / SELECT INTO #temp. Run on the CountyScansTitle server.
Real lease types (excluded from the "non-lease" set): MOGL, OGL, POGL, ROGL, OGLAMD, OGLEXT. REOGL is kept in scope but labelled so it can be judged separately.
Result 1: tbllookupInstTypes rows for every instrument type that shows up, so the lookup's own lease/non-lease flag columns (if any) are visible.
Result 2: per instrument type, how many recordIsLease = 1 rows are (a) already exported, (b) eligible and unexported but stuck on a join, (c) eligible and unexported and exportable. (a) and (c) are non-lease documents that reach or will reach DS9 legal_lease.
Result 3: stuck and exportable non-lease rows by state, county, instrument type and month created.
Result 4: actual rows for every eligible unexported non-lease record, so each type can be eyeballed.
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#NonLease') IS NOT NULL DROP TABLE #NonLease;

SELECT R.recordID, R.countyID, R.recordNumber, R.volume, R.page, R.statusID, R.instrumentTypeID, R.fileDate, R._CreatedDateTime, R._ModifiedDateTime,
       CASE WHEN E.recordID IS NOT NULL THEN 1 ELSE 0 END AS isExported,
       CASE WHEN T.Code IS NULL THEN 1 ELSE 0 END AS noInstType,
       CASE WHEN GR.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantor,
       CASE WHEN GE.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantee
INTO #NonLease
FROM [countyScansTitle].[dbo].[tblrecord] AS R WITH (NOLOCK)
LEFT JOIN [countyScansTitle].[dbo].[tbllookupInstTypes] AS T ON T.Code = R.instrumentTypeID
LEFT JOIN (SELECT DISTINCT recordID FROM [countyScansTitle].[dbo].[tblexportLog] WITH (NOLOCK)) AS E ON E.recordID = R.recordID
OUTER APPLY (SELECT TOP 1 1 AS hasRow FROM [countyScansTitle].[dbo].[tblgrantorGrantee] AS G WITH (NOLOCK)
             WHERE G.recordID = CONVERT(VARCHAR(36), R.recordID) AND G.recordType = 'grantor' AND G.IsDeleted = 0) AS GR
OUTER APPLY (SELECT TOP 1 1 AS hasRow FROM [countyScansTitle].[dbo].[tblgrantorGrantee] AS G WITH (NOLOCK)
             WHERE G.recordID = CONVERT(VARCHAR(36), R.recordID) AND G.recordType = 'grantee' AND G.IsDeleted = 0) AS GE
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 16)
  AND R.fileDate >= '2002-01-01'
  AND R.countyID NOT IN (288,291,292,293,295,296,298,300,684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
                         700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,1187)
  AND (R.instrumentTypeID IS NULL OR R.instrumentTypeID NOT IN ('MOGL', 'OGL', 'POGL', 'ROGL', 'OGLAMD', 'OGLEXT'));

-- 1. Lookup rows for every instrument type present.
SELECT T.*
FROM [countyScansTitle].[dbo].[tbllookupInstTypes] AS T
WHERE T.Code IN (SELECT DISTINCT instrumentTypeID FROM #NonLease WHERE instrumentTypeID IS NOT NULL)
ORDER BY T.Code;

-- 2. Per instrument type: exported vs stuck vs exportable.
SELECT ISNULL(N.instrumentTypeID, '(null)') AS instrumentTypeID,
       CASE WHEN N.instrumentTypeID = 'REOGL' THEN 'REOGL (maybe a lease)' ELSE 'non-lease' END AS bucket,
       COUNT(*) AS totalRecordIsLease1,
       SUM(CASE WHEN N.isExported = 1 THEN 1 ELSE 0 END) AS alreadyExported,
       SUM(CASE WHEN N.isExported = 0 AND (N.noInstType = 1 OR N.noGrantor = 1 OR N.noGrantee = 1) THEN 1 ELSE 0 END) AS unexportedStuck,
       SUM(CASE WHEN N.isExported = 0 AND N.noInstType = 0 AND N.noGrantor = 0 AND N.noGrantee = 0 THEN 1 ELSE 0 END) AS unexportedExportable,
       MIN(N._CreatedDateTime) AS firstCreated, MAX(N._CreatedDateTime) AS lastCreated
FROM #NonLease AS N
GROUP BY N.instrumentTypeID
ORDER BY totalRecordIsLease1 DESC;

-- 3. Unexported non-lease rows by state, county, type and month created.
SELECT S2.stateAbbreviation, C.countyName, N.countyID, ISNULL(N.instrumentTypeID, '(null)') AS instrumentTypeID,
       CONVERT(CHAR(7), N._CreatedDateTime, 120) AS createdMonth,
       SUM(CASE WHEN N.noInstType = 1 OR N.noGrantor = 1 OR N.noGrantee = 1 THEN 1 ELSE 0 END) AS stuck,
       SUM(CASE WHEN N.noInstType = 0 AND N.noGrantor = 0 AND N.noGrantee = 0 THEN 1 ELSE 0 END) AS exportable
FROM #NonLease AS N
LEFT JOIN [countyScansTitle].[dbo].[tbllookupCounties] AS C ON C.CountyID = N.countyID
LEFT JOIN [countyScansTitle].[dbo].[tbllookupStates] AS S2 ON S2.StateID = C.StateID
WHERE N.isExported = 0
GROUP BY S2.stateAbbreviation, C.countyName, N.countyID, N.instrumentTypeID, CONVERT(CHAR(7), N._CreatedDateTime, 120)
ORDER BY stuck DESC, exportable DESC;

-- 4. Every unexported non-lease record.
SELECT S2.stateAbbreviation, C.countyName, N.countyID, N.recordNumber, N.volume, N.page, N.instrumentTypeID, N.fileDate, N.statusID,
       N.noInstType, N.noGrantor, N.noGrantee, N._CreatedDateTime, N._ModifiedDateTime, N.recordID
FROM #NonLease AS N
LEFT JOIN [countyScansTitle].[dbo].[tbllookupCounties] AS C ON C.CountyID = N.countyID
LEFT JOIN [countyScansTitle].[dbo].[tbllookupStates] AS S2 ON S2.StateID = C.StateID
WHERE N.isExported = 0
ORDER BY N.instrumentTypeID, S2.stateAbbreviation, C.countyName, N.recordNumber;
