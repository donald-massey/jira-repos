/* ============================================================================
   LND-8426 — Mapping-id split: quantify who gets dropped from legal_lease.

   Purpose: the glue legal_lease writer keeps only records with
   mapping_id IS NOT NULL. mapping_id (= DIV1 tblleaseAbstractMapping.mappingid)
   exists only when a lease is mapped to an abstract in DIV1. This script
   measures how many candidate leases HAVE a mapping vs NOT, broken down by
   state, to test whether the NULLs cluster in PA/OH/WV (StateID 93/91/102).

   If the unmapped share is ~random across states -> generic data-quality miss.
   If it spikes for PA/OH/WV -> confirms those states lack the abstract mapping
   / land grid, and the fix is an explicit upstream decision, not a pipeline bug.

   Two servers are involved. Run everything ON THE CSTITLE SERVER: the DIV1
   mapped-lease set is pulled across the CSTitle->DIV1 linked server via
   OPENQUERY into #mapped_leases (Pass B, step 1), and the CSTitle universe +
   state join classifies each candidate. Pass A blocks are DIV1-side reads
   (run via the link or directly on DIV1). Replace <LINK> with the linked server.

     PA = 93,  OH = 91,  WV = 102
   ============================================================================ */


/* ----------------------------------------------------------------------------
   PASS A — DIV1 (div1_Daily, V02PDIPRODDIV01.PROD.AUS): the mapped side.
   Distinct leases that have ANY abstract mapping, grouped by state. This alone
   shows the mapped-lease distribution by state (the numerator's home).
   ---------------------------------------------------------------------------- */
SELECT a.StateID,
       st.state_name,
       COUNT(DISTINCT m.LeaseID) AS mapped_leases
FROM dbo.tblleaseAbstractMapping m
JOIN dbo.tblAbstract a ON a.AbstractID = m.abstractID
JOIN dbo.tblState   st ON st.StateID   = a.StateID
GROUP BY a.StateID, st.state_name
ORDER BY mapped_leases DESC;


/* ----------------------------------------------------------------------------
   PASS A helper — the raw mapped-lease id list, to carry into CSTitle.
   Export this result set (or push it into a temp/staging table in the CSTitle
   DB, e.g. #mapped_leases below) for the combine in Pass B.
   ---------------------------------------------------------------------------- */
SELECT DISTINCT m.LeaseID
FROM dbo.tblleaseAbstractMapping m;


/* ----------------------------------------------------------------------------
   PASS A — cross-section of mapping activity over time (DIV1).
   Uses dbo.tblleaseAbstractMapping.created / .updated to show WHEN mappings are
   being created vs revised, by state and month. Read it as: are OH/PA/WV mappings
   a flat historical gap (little/no recent activity) or actively being built?
   A rising 'created' count for the three states = the gap is closing upstream;
   flat/zero = the land descriptions simply aren't being sourced there.
   ---------------------------------------------------------------------------- */
SELECT st.state_name,
       DATEFROMPARTS(YEAR(m.created), MONTH(m.created), 1)              AS created_month,
       COUNT(*)                                                          AS mappings_created,
       SUM(CASE WHEN m.updated > m.created THEN 1 ELSE 0 END)            AS later_revised
FROM dbo.tblleaseAbstractMapping m
JOIN dbo.tblAbstract a ON a.AbstractID = m.abstractID
JOIN dbo.tblState   st ON st.StateID   = a.StateID
WHERE m.created IS NOT NULL
GROUP BY st.state_name, DATEFROMPARTS(YEAR(m.created), MONTH(m.created), 1)
ORDER BY created_month DESC, mappings_created DESC;


/* ----------------------------------------------------------------------------
   PASS A — same cross-section, three-state focus (OH/PA/WV, by month).
   Filtered to the Marcellus states so the follow-up ticket can cite the recent
   creation cadence directly.
   ---------------------------------------------------------------------------- */
SELECT st.state_name,
       DATEFROMPARTS(YEAR(m.created), MONTH(m.created), 1)              AS created_month,
       COUNT(*)                                                          AS mappings_created,
       COUNT(DISTINCT m.LeaseID)                                         AS distinct_leases,
       SUM(CASE WHEN m.updated > m.created THEN 1 ELSE 0 END)            AS later_revised,
       MAX(m.created)                                                    AS most_recent_created
FROM dbo.tblleaseAbstractMapping m
JOIN dbo.tblAbstract a ON a.AbstractID = m.abstractID
JOIN dbo.tblState   st ON st.StateID   = a.StateID
WHERE a.StateID IN (91, 102, 93)   -- OH / WV / PA
  AND m.created IS NOT NULL
GROUP BY st.state_name, DATEFROMPARTS(YEAR(m.created), MONTH(m.created), 1)
ORDER BY st.state_name, created_month DESC;


/* ----------------------------------------------------------------------------
   PASS A — county-level coverage within a Marcellus state (DIV1).
   The state total hides county gaps: PA gets thousands of NEW mappings/month,
   but they concentrate in the core Marcellus counties. A fringe county like
   COLUMBIA (where lease 4696618 lives) can be near-zero while the state looks
   healthy. Starts from tblCounty so counties with NO abstracts (no land grid at
   all) still show up as a zero row instead of vanishing.

   Read: counties sorted to the top with 0 abstracts / 0 mapped_leases are outside
   the mapping footprint -> any lease there gets no mapping_id -> dropped.
   Change a.StateID / c.StateID to 91 (OH) or 102 (WV) to repeat per state.
   ---------------------------------------------------------------------------- */
SELECT c.CountyName,
       COUNT(DISTINCT a.AbstractID)   AS abstracts,        -- land grid present?
       COUNT(DISTINCT m.LeaseID)      AS mapped_leases,     -- leases actually mapped
       MAX(m.created)                 AS most_recent_created
FROM dbo.tblCounty c
LEFT JOIN dbo.tblAbstract a
       ON a.CountyID = c.CountyID AND a.StateID = 93        -- PA
LEFT JOIN dbo.tblleaseAbstractMapping m
       ON m.abstractID = a.AbstractID
WHERE c.StateID = 93                                        -- PA (verify tblCounty.StateID exists)
GROUP BY c.CountyName
ORDER BY mapped_leases ASC, abstracts ASC;                  -- gaps first


/* ----------------------------------------------------------------------------
   PASS A — direct look at COLUMBIA, PA (lease 4696618's county).
   Zero abstracts  -> no land grid was ever built for the county (root cause).
   Abstracts but 0/low mapped_leases -> grid exists, leases just aren't mapped.
   ---------------------------------------------------------------------------- */
SELECT c.CountyName,
       COUNT(DISTINCT a.AbstractID) AS abstracts,
       COUNT(DISTINCT m.LeaseID)    AS mapped_leases,
       MIN(m.created)               AS first_created,
       MAX(m.created)               AS most_recent_created
FROM dbo.tblCounty c
LEFT JOIN dbo.tblAbstract a
       ON a.CountyID = c.CountyID AND a.StateID = 93
LEFT JOIN dbo.tblleaseAbstractMapping m
       ON m.abstractID = a.AbstractID
WHERE c.StateID = 93
  AND c.CountyName = 'COLUMBIA'
GROUP BY c.CountyName;


/* ----------------------------------------------------------------------------
   PASS B — CSTitle (countyScansTitle): the candidate publish universe.
   This is the same population land-lease-producer walks: lease records in a
   publishable status. tblexportLog.leaseID is the DIV1 LeaseID for each record.

   Run this whole section ON THE CSTITLE SERVER. The DIV1 mapped-lease ids come
   across the CSTitle->DIV1 linked server via OPENQUERY (no CSV / bcp needed).
   Populate #mapped_leases ONCE here, then every split below joins it.
   Replace <LINK> with the linked-server name.
   ---------------------------------------------------------------------------- */

-- 1) stage the DIV1 mapped-lease ids across the linked server (pulled once).
--    DISTINCT runs on the DIV1 side so only ~4.8M deduped ids ship, not ~24M rows.
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl], 'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping');

-- 2) the split: candidate leases classified mapped vs unmapped, by state.
--    State comes from tblRecord.stateID -> tblLookupStates (the path the
--    producer uses: LEFT JOIN tblLookupStates ON R.stateID = s.StateID).
SELECT S.stateAbbreviation,
       COUNT(*)                                                       AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NOT NULL THEN 1 ELSE 0 END)        AS has_mapping_id,
       SUM(CASE WHEN ml.LeaseID IS NULL     THEN 1 ELSE 0 END)        AS no_mapping_id,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))              AS pct_dropped
FROM dbo.tblRecord R
JOIN dbo.tblexportLog    L  ON L.recordID = R.recordID
JOIN dbo.tblLookupStates S  ON S.StateID  = R.stateID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND L.leaseID IS NOT NULL
GROUP BY S.stateAbbreviation
ORDER BY pct_dropped DESC, candidate_leases DESC;

-- DROP TABLE #mapped_leases;


/* ----------------------------------------------------------------------------
   PASS B — three-state focus (PA/OH/WV vs the rest).
   Same #mapped_leases stage as above. Collapses every non-target state into one
   'OTHER' bucket so the PA / OH / WV contrast is a single glance — this is the
   cut to reference in the follow-up ticket.
   ---------------------------------------------------------------------------- */
SELECT CASE WHEN S.stateAbbreviation IN ('PA','OH','WV')
            THEN S.stateAbbreviation ELSE 'OTHER (all remaining states)' END AS state_bucket,
       COUNT(*)                                                           AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NOT NULL THEN 1 ELSE 0 END)            AS has_mapping_id,
       SUM(CASE WHEN ml.LeaseID IS NULL     THEN 1 ELSE 0 END)            AS no_mapping_id,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                  AS pct_dropped
FROM dbo.tblRecord R
JOIN dbo.tblexportLog    L  ON L.recordID = R.recordID
JOIN dbo.tblLookupStates S  ON S.StateID  = R.stateID
LEFT JOIN #mapped_leases ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND L.leaseID IS NOT NULL
GROUP BY CASE WHEN S.stateAbbreviation IN ('PA','OH','WV')
              THEN S.stateAbbreviation ELSE 'OTHER (all remaining states)' END
ORDER BY pct_dropped DESC;


/* ----------------------------------------------------------------------------
   PASS B — COLUMBIA, PA sizing (lease 4696618's county).
   Reuses #mapped_leases. Answers whether 4696618 is a lone miss or the county
   has a large unmapped backlog — the number that decides if a fringe-county
   backfill is worth its own ticket. Swap the county/state to repeat elsewhere.
   ---------------------------------------------------------------------------- */
SELECT COUNT(*)                                                   AS candidate_leases,
       SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)        AS unmapped,
       CAST(100.0 * SUM(CASE WHEN ml.LeaseID IS NULL THEN 1 ELSE 0 END)
                  / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))          AS pct_unmapped
FROM dbo.tblRecord R
JOIN dbo.tblexportLog     L  ON L.recordID = R.recordID
JOIN dbo.tblLookupStates  S  ON S.StateID  = R.stateID
JOIN dbo.tblLookupCounties C ON C.countyID = R.countyID
LEFT JOIN #mapped_leases  ml ON ml.LeaseID = L.leaseID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10)
  AND L.leaseID IS NOT NULL
  AND S.stateAbbreviation = 'PA'
  AND C.CountyName = 'COLUMBIA';

-- DROP TABLE #mapped_leases;
