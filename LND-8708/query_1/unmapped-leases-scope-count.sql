/* ============================================================================
   Spike: publish LegalLeases without abstract/mapping entries
   Scope count — how many published leases have NO abstract mapping in DIV1.

   Follow-on to LND-8426. These are the "zero-mapping" leases: exported to Kafka,
   flagged as a lease, but with no tblleaseAbstractMapping entry in DIV1 -> no
   mapping_id -> dropped from the legal_lease ES index today.

   RUN ON:  the countyScansTitle server (aus2-dtf-pap01v.na.drillinginfo.com),
            which has linked server [LinktoDiv1Repl] to DIV1.
            (The reverse link does not exist on the DIV1 GIS server, so the
             query must originate here.)

   VERIFY BEFORE RUNNING:
     - Catalog name via the link: div1_Daily vs. a repl DB (link is named ...Repl).
       Confirm the 2nd part of the four-part name resolves.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   STEP 1 — Stage DIV1 mapped leases across the linked server (pulled once).
   DISTINCT runs on the DIV1 side so only deduped ids ship, not the full table.
   ---------------------------------------------------------------------------- */
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl],
    'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping');


/* ----------------------------------------------------------------------------
   STEP 2 — Zero-mapping leases by state.
   Of the leases published to Kafka (tblexportLog) that are in a publishable
   status, how many have no entry in DIV1 tblleaseAbstractMapping?
   State joins from tblRecord.stateID -> tblLookupStates (same path as LND-8426).
   ---------------------------------------------------------------------------- */
SELECT S.stateAbbreviation,
       COUNT(DISTINCT E.LeaseID)                                        AS zero_mapping_leases
FROM dbo.tblexportLog E
JOIN dbo.tblRecord       R  ON R.RecordID = E.recordID
JOIN dbo.tblLookupStates S  ON S.StateID  = R.stateID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = E.LeaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND E.LeaseID IS NOT NULL
  AND ml.LeaseID IS NULL          -- anti-join: no mapping in DIV1
GROUP BY S.stateAbbreviation
ORDER BY zero_mapping_leases DESC;


/* ----------------------------------------------------------------------------
   STEP 3 — Grand total across all states.
   ---------------------------------------------------------------------------- */
SELECT COUNT(DISTINCT E.LeaseID) AS total_zero_mapping_leases
FROM dbo.tblexportLog E
JOIN dbo.tblRecord       R  ON R.RecordID = E.recordID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = E.LeaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND E.LeaseID IS NOT NULL
  AND ml.LeaseID IS NULL;


DROP TABLE #mapped_leases;
