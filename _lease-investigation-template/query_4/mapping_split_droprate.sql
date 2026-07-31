/* ============================================================================
   {TICKET} — scale check: mapping_id drop rate by state / county
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Answers: is this record a one-off, or a county/state pattern? Cut the rate from
   the candidate publish universe (NOT absolute mapped counts, which track state size).

   Run ENTIRELY on the CSTitle server. Step 1 stages DIV1 mapped-lease ids across
   the CSTitle->DIV1 linked server; steps 2-3 classify the CSTitle candidate universe.
   {LINK} = linked-server name (e.g. LinktoDiv1Repl).
   ============================================================================ */

/* 1) Stage DIV1 mapped-lease ids (DISTINCT runs DIV1-side). */
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([{LINK}], 'SELECT DISTINCT LeaseID FROM Div1_Daily.dbo.tblleaseAbstractMapping');

/* 2) Drop rate by state. */
SELECT S.stateAbbreviation,
       COUNT(*)                                                AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NOT NULL THEN 1 ELSE 0 END) AS has_mapping_id,
       SUM(CASE WHEN ml.LeaseID IS NULL     THEN 1 ELSE 0 END) AS no_mapping_id,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))        AS pct_dropped
FROM [countyScansTitle].[dbo].[tblRecord]        R
JOIN [countyScansTitle].[dbo].[tblexportLog]     L ON L.recordID = R.recordID
JOIN [countyScansTitle].[dbo].[tblLookupStates]  S ON S.StateID  = R.stateID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1 AND R.statusID IN (4, 10) AND L.leaseID IS NOT NULL
GROUP BY S.stateAbbreviation
ORDER BY pct_dropped DESC, candidate_leases DESC;

/* 3) County sizing within the target state. */
SELECT COUNT(*)                                                AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)     AS unmapped,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))        AS pct_unmapped
FROM [countyScansTitle].[dbo].[tblRecord]          R
JOIN [countyScansTitle].[dbo].[tblexportLog]       L ON L.recordID = R.recordID
JOIN [countyScansTitle].[dbo].[tblLookupStates]    S ON S.StateID  = R.stateID
JOIN [countyScansTitle].[dbo].[tblLookupCounties]  C ON C.countyID = R.countyID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1 AND R.statusID IN (4, 10) AND L.leaseID IS NOT NULL
  AND S.stateAbbreviation = '{STATE}' AND C.CountyName = '{COUNTY}';

-- DROP TABLE #mapped_leases;

/* Note: the candidate universe uses statusID IN (4,10) (runbook). The producer's
   modified filter also emits statusID 16 (cstitle_get_modified_instrument_ids.sql),
   but is_active in cstitle_get_instruments.sql only maps (4,10)->1 / 11->0, so 16 -> NULL.
   Widen to (4,10,16) here if you need to reconcile against the producer's exact selection. */
