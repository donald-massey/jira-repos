-- MI drop-rate by county: of all candidate leases (recordIsLease = 1,
-- statusID IN (4, 10), non-null leaseID), what share has no DIV1 abstract mapping.
-- Adapted from LND-8426 state-level analysis. Run against countyScansTitle.
-- Replace <LINK> with the linked-server name (e.g. LinktoDiv1Repl).

CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);

INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY(
    [LinktoDiv1Repl],
    'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping'
);

SELECT
    C.CountyName                                                         AS county_name,
    COUNT(*)                                                             AS candidate_leases,
    SUM(CASE WHEN ml.LeaseID IS NOT NULL THEN 1 ELSE 0 END)             AS has_mapping,
    SUM(CASE WHEN ml.LeaseID IS NULL     THEN 1 ELSE 0 END)             AS no_mapping,
    CAST(
        100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
    AS DECIMAL(5,2))                                                     AS pct_dropped
FROM dbo.tblRecord R
JOIN dbo.tblexportLog      el ON el.recordID  = R.recordID
JOIN dbo.tblLookupCounties C  ON C.CountyID   = R.countyID
JOIN dbo.tblLookupStates   S  ON S.StateID    = R.stateID
LEFT JOIN #mapped_leases   ml ON ml.LeaseID   = el.leaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND el.leaseID IS NOT NULL
  AND S.stateAbbreviation = 'MI'
GROUP BY C.CountyName
ORDER BY pct_dropped DESC, candidate_leases DESC;

DROP TABLE #mapped_leases;
