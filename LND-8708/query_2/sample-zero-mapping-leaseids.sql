/* ============================================================================
   LND-8708 Query 2 helper — pull a handful of zero-mapping lease IDs to publish
   in the Dev run. Returns the fields the producer debug overrides need:
     - recordID   (GUID)  -> hardcode in get_modified_instrument_ids()
     - CountyName + state -> restrict the producer county loop
     - LeaseID            -> the Kafka key (lease::{LeaseID}) to verify in ES

   RUN ON: CSTitle server (aus2-dtf-pap01v.na.drillinginfo.com), same anti-join
   as query_1. Stage #mapped_leases first (STEP 1 of unmapped-leases-scope-count.sql).

   Field population is state-independent (all five description arrays are empty
   for these leases), so a couple is enough. Suggested set: 4696618 (COLUMBIA PA,
   the LND-8426 known-good repro) + a few TX (the dominant state) for realism.
   ============================================================================ */

IF OBJECT_ID('tempdb..#mapped_leases') IS NOT NULL DROP TABLE #mapped_leases;
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl],
    'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping');


/* A few TX zero-mapping leases (dominant state). Bump TOP as needed. */
SELECT TOP (10)
       E.LeaseID,
       E.recordID,
       C.CountyName,
       S.stateAbbreviation
FROM dbo.tblexportLog E
JOIN dbo.tblRecord            R  ON R.recordID  = E.recordID
JOIN dbo.tblLookupStates      S  ON S.StateID   = R.stateID
JOIN dbo.tblLookupCounties    C  ON C.countyID  = R.countyID
LEFT JOIN #mapped_leases      ml ON ml.LeaseID  = E.LeaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND E.LeaseID IS NOT NULL
  AND ml.LeaseID IS NULL
  AND S.stateAbbreviation = 'TX'
ORDER BY E.LeaseID DESC;


/* The LND-8426 known-good repro (COLUMBIA PA, LeaseID 4696618). Confirm it is
   still zero-mapping and pull its recordID for the producer override. */
SELECT E.LeaseID,
       E.recordID,
       C.CountyName,
       S.stateAbbreviation
FROM dbo.tblexportLog E
JOIN dbo.tblRecord            R  ON R.recordID  = E.recordID
JOIN dbo.tblLookupStates      S  ON S.StateID   = R.stateID
JOIN dbo.tblLookupCounties    C  ON C.countyID  = R.countyID
LEFT JOIN #mapped_leases      ml ON ml.LeaseID  = E.LeaseID
WHERE E.LeaseID = 4696618
  AND ml.LeaseID IS NULL;

DROP TABLE #mapped_leases;
