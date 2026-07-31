/* ============================================================================
   LND-8425 — Scale check: mapping-id drop rate by state, and MIAMI/KS sizing.
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Confirms whether the MIAMI, KS miss (LeaseID 5184347) is a per-record
   singleton or part of a county/state pattern. In the LND-8426 analysis KS
   was <1% dropped ("omitted for brevity" bucket), so a singleton like
   COLUMBIA, PA (4696618) is expected.

   Run ENTIRELY on the CSTitle server. Step 1 pulls the DIV1 mapped-lease ids
   across the CSTitle->DIV1 linked server via OPENQUERY into a temp table;
   the splits join the CSTitle candidate universe against it.
   Linked server = LinktoDiv1Repl (same as LND-8426).
   ============================================================================ */

-- 1) Stage DIV1 mapped-lease ids across the linked server (DISTINCT runs DIV1-side).
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl], 'SELECT DISTINCT LeaseID FROM [div1_Daily].[dbo].[tblleaseAbstractMapping]');


-- 2) Drop rate by state (candidate universe classified mapped vs unmapped).
--    Confirms KS's overall drop rate against the LND-8426 table.
SELECT S.stateAbbreviation,
       COUNT(*)                                                   AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NOT NULL THEN 1 ELSE 0 END)    AS has_mapping_id,
       SUM(CASE WHEN ml.LeaseID IS NULL     THEN 1 ELSE 0 END)    AS no_mapping_id,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))          AS pct_dropped
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN [countyScansTitle].[dbo].[tblexportLog]    L  ON L.recordID = R.recordID
JOIN [countyScansTitle].[dbo].[tblLookupStates] S  ON S.StateID  = R.stateID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1 AND R.statusID IN (4, 10) AND L.leaseID IS NOT NULL
GROUP BY S.stateAbbreviation
ORDER BY pct_dropped DESC, candidate_leases DESC;


-- 3) MIAMI, KS county sizing — is 5184347 a lone miss or a county backlog?
SELECT COUNT(*)                                                   AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)        AS unmapped,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))          AS pct_unmapped
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN [countyScansTitle].[dbo].[tblexportLog]     L  ON L.recordID = R.recordID
JOIN [countyScansTitle].[dbo].[tblLookupStates]  S  ON S.StateID  = R.stateID
JOIN [countyScansTitle].[dbo].[tblLookupCounties] C ON C.countyID = R.countyID
LEFT JOIN #mapped_leases  ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1 AND R.statusID IN (4, 10) AND L.leaseID IS NOT NULL
  AND S.stateAbbreviation = 'KS' AND C.CountyName = 'MIAMI';


-- 4) The unmapped MIAMI, KS records themselves (list them for the ticket).
--    5184347 should appear here if it is unmapped.
SELECT R.recordID, R.recordNumber, R.fileDate, L.leaseID
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN [countyScansTitle].[dbo].[tblexportLog]     L  ON L.recordID = R.recordID
JOIN [countyScansTitle].[dbo].[tblLookupStates]  S  ON S.StateID  = R.stateID
JOIN [countyScansTitle].[dbo].[tblLookupCounties] C ON C.countyID = R.countyID
LEFT JOIN #mapped_leases  ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1 AND R.statusID IN (4, 10) AND L.leaseID IS NOT NULL
  AND S.stateAbbreviation = 'KS' AND C.CountyName = 'MIAMI'
  AND ml.LeaseID IS NULL
ORDER BY R.fileDate DESC;

DROP TABLE #mapped_leases;
