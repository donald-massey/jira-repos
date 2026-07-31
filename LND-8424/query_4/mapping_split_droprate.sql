/* ============================================================================
   LND-8424 — scale check: mapping_id drop rate, CA + MERCED
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Is MERCED 2024017111 a one-off, or a CA/MERCED pattern? Cut the rate from the
   candidate publish universe (NOT absolute mapped counts, which track state size).
   Runbook baseline: CA = 2.59% dropped (80 / 3,088). MERCED sizing is step 3.

   Run ENTIRELY on the CSTitle server (AUS2-PHX-DSQL01). Step 1 stages DIV1 ids
   across the CSTitle->DIV1 linked server. {LINK} default: LinktoDiv1Repl.
   ============================================================================ */

/* 1) Stage DIV1 mapped-lease ids (DISTINCT runs DIV1-side). */
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl], 'SELECT DISTINCT LeaseID FROM Div1_Daily.dbo.tblleaseAbstractMapping');

/* 2) Drop rate by state (confirm CA against the 2.59% baseline). */
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

/* 3) MERCED sizing within CA. */
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
  AND S.stateAbbreviation = 'CA' AND C.CountyName = 'MERCED';

-- DROP TABLE #mapped_leases;

/* Note: candidate universe uses statusID IN (4,10) (runbook). The producer's modified
   filter also emits statusID 16, but is_active only maps (4,10)->1 / 11->0 so 16 -> NULL.
   If MERCED's records are statusID 16 (check query_1), widen to (4,10,16) to reconcile. */
