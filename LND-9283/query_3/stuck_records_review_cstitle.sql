/*
LND-9283 diagnostic, CSTitle server: one review sheet covering every stuck record, to check for a wrong instrument type in either direction.
(a) non-lease or no-type rows that are actually leases, (b) lease-type rows (MOGL, OGL, POGL, ROGL, OGLAMD, OGLEXT) that are actually not leases.
READ-ONLY. Only SELECT / SELECT INTO #temp. Run on the CountyScansTitle server.
Scope: the stuck set (eligible unexported recordIsLease = 1 rows failing an instrument type, grantor or grantee join), same filter as LND-7358/query_38.
Result 1: one row per group (state + county + instrumentTypeID + created date) with its size. Bulk loads show up as large groups.
Result 2: every stuck record with an image path and blank review columns. Save as stuck_records_review.csv and work through it.
        Fill actualDocType, isLease (Y or N), action (REKEY or STATUS17) and notes.
        REKEY: a real lease, data entry re-keys it. STATUS17: not a lease, set recordIsLease 0 and StatusID 17 (run manually).
        imagePath follows the gpdm_imagestore convention (<County>_IMAGES\<first 4 of recordID>\<recordID>.pdf); verify it on multi-word county names.
Rows are ordered by group so a bulk load sits together and can be reviewed in one pass.
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Stuck') IS NOT NULL DROP TABLE #Stuck;

SELECT R.recordID, R.countyID, R.recordNumber, R.volume, R.page, R.statusID, R.instrumentTypeID, R.fileDate, R._CreatedDateTime,
       CASE WHEN T.Code IS NULL THEN 1 ELSE 0 END AS noInstType,
       CASE WHEN GR.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantor,
       CASE WHEN GE.hasRow IS NULL THEN 1 ELSE 0 END AS noGrantee,
       CASE WHEN R.instrumentTypeID IN ('MOGL', 'OGL', 'POGL', 'ROGL', 'OGLAMD', 'OGLEXT') THEN 'lease type'
            WHEN R.instrumentTypeID IS NULL THEN 'no type'
            WHEN R.instrumentTypeID = 'REOGL' THEN 'REOGL'
            ELSE 'non-lease type' END AS direction
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

IF OBJECT_ID('tempdb..#Grouped') IS NOT NULL DROP TABLE #Grouped;

SELECT S.*, S2.stateAbbreviation, C.countyName,
       CONVERT(CHAR(10), S._CreatedDateTime, 120) AS createdDate,
       COUNT(*) OVER (PARTITION BY S.countyID, S.instrumentTypeID, CONVERT(CHAR(10), S._CreatedDateTime, 120)) AS groupSize
INTO #Grouped
FROM #Stuck AS S
LEFT JOIN [countyScansTitle].[dbo].[tbllookupCounties] AS C ON C.CountyID = S.countyID
LEFT JOIN [countyScansTitle].[dbo].[tbllookupStates] AS S2 ON S2.StateID = C.StateID;

-- 1. One row per group.
SELECT direction, stateAbbreviation, countyName, countyID, ISNULL(instrumentTypeID, '(null)') AS instrumentTypeID, createdDate,
       groupSize,
       SUM(CASE WHEN noGrantor = 1 THEN 1 ELSE 0 END) AS noGrantor,
       SUM(CASE WHEN noGrantee = 1 THEN 1 ELSE 0 END) AS noGrantee
FROM #Grouped
GROUP BY direction, stateAbbreviation, countyName, countyID, instrumentTypeID, createdDate, groupSize
ORDER BY direction, groupSize DESC, stateAbbreviation, countyName;

-- 2. Review sheet: every stuck record; actualDocType, isLease, action and notes left blank.
SELECT direction, stateAbbreviation, countyName, countyID, recordNumber, volume, page, ISNULL(instrumentTypeID, '(null)') AS instrumentTypeID,
       fileDate, statusID, noInstType, noGrantor, noGrantee, createdDate, groupSize, recordID,
       '\\aus2-cs-fss01.na.drillinginfo.com\CS_TitleImages\CountyScansTitleImages\gpdm_imagestore\' + countyName + '_IMAGES\'
         + LEFT(LOWER(CONVERT(VARCHAR(36), recordID)), 4) + '\' + LOWER(CONVERT(VARCHAR(36), recordID)) + '.pdf' AS imagePath,
       '' AS actualDocType, '' AS isLease, '' AS action, '' AS notes
FROM #Grouped
ORDER BY direction, instrumentTypeID, stateAbbreviation, countyName, createdDate, recordNumber;
