/* ============================================================================
   LND-8708 Query 2 helper — pull 1,000 MAPPED + 1,000 UNMAPPED lease record IDs
   to publish in the local Dev run. Controlling volume at the PRODUCER (publish
   exactly these to a fresh test topic) keeps the glue Kafka read fast and lets
   us pin a known mapped lease_id for the clobber check — so the glue-side
   .limit(1000) caps come out entirely.

   Returns, for each set:
     - recordID  (GUID)  -> paste into CSTitleLeaseDataProvider.get_modified_instrument_ids()
     - LeaseID           -> the Kafka key (lease::{LeaseID}) to verify in ES
     - CountyName + state -> context only (producer fetches by GUID, not county)

   RUN ON: CSTitle server (aus2-dtf-pap01v.na.drillinginfo.com), same anti-join
   as query_1 (STEP 1 stages DIV1 mapped leases via LinktoDiv1Repl).

   NOTE ON GRAIN: a MAPPED lease can carry multiple abstract mappings, so 1,000
   mapped leases yield >= 1,000 df1 docs (one per mapping_id). 1,000 UNMAPPED
   leases yield exactly 1,000 df2 docs (one per lease_id). That's expected.
   ============================================================================ */

IF OBJECT_ID('tempdb..#mapped_leases') IS NOT NULL DROP TABLE #mapped_leases;
CREATE TABLE #mapped_leases (LeaseID BIGINT PRIMARY KEY);
INSERT INTO #mapped_leases (LeaseID)
SELECT LeaseID
FROM OPENQUERY([LinktoDiv1Repl],
    'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping');


/* ----------------------------------------------------------------------------
   Reusable base: currently-publishable, exported leases with their recordID.
   #base is the exported/publishable universe; the mapped/unmapped split is the
   INNER vs ANTI join to #mapped_leases.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#base') IS NOT NULL DROP TABLE #base;
SELECT E.LeaseID,
       E.recordID,
       R.countyID                                              AS cstitle_county_id,
       C.CountyName,
       S.stateAbbreviation,
       CASE WHEN ml.LeaseID IS NULL THEN 0 ELSE 1 END AS is_mapped
INTO   #base
FROM   dbo.tblexportLog        E
JOIN   dbo.tblRecord           R  ON R.recordID  = E.recordID
JOIN   dbo.tblLookupStates     S  ON S.StateID   = R.stateID
JOIN   dbo.tblLookupCounties   C  ON C.countyID  = R.countyID
LEFT JOIN #mapped_leases       ml ON ml.LeaseID  = E.LeaseID
WHERE  R.recordIsLease = 1
  AND  R.statusID IN (4, 10)
  AND  E.LeaseID IS NOT NULL;


/* ----------------------------------------------------------------------------
   #sel — the chosen 1,000 mapped + 1,000 unmapped, CONCENTRATED into as few
   counties as possible (not scattered). Within each bucket, rank counties by how
   many qualifying leases they hold and take from the densest counties first, so
   the producer iterates a handful of county loops instead of hundreds.
   ---------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#sel') IS NOT NULL DROP TABLE #sel;
;WITH cnt AS (
    SELECT LeaseID, recordID, cstitle_county_id, CountyName, stateAbbreviation, is_mapped,
           COUNT(*) OVER (PARTITION BY is_mapped, cstitle_county_id) AS county_cnt
    FROM #base
), ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY is_mapped
                              ORDER BY county_cnt DESC, cstitle_county_id, LeaseID DESC) AS rn
    FROM cnt
)
SELECT LeaseID, recordID, cstitle_county_id, CountyName, stateAbbreviation, is_mapped
INTO   #sel
FROM   ranked
WHERE  rn <= 1000;


/* SET A — 1,000 MAPPED leases (df1), grouped by county. */
SELECT 'MAPPED' AS bucket, LeaseID, recordID, cstitle_county_id, CountyName, stateAbbreviation
FROM   #sel WHERE is_mapped = 1
ORDER BY cstitle_county_id, LeaseID DESC;

/* SET B — 1,000 UNMAPPED leases (df2), grouped by county. */
SELECT 'UNMAPPED' AS bucket, LeaseID, recordID, cstitle_county_id, CountyName, stateAbbreviation
FROM   #sel WHERE is_mapped = 0
ORDER BY cstitle_county_id, LeaseID DESC;

/* How concentrated: one row per county with its lease count (fewer rows = fewer producer loops). */
SELECT cstitle_county_id, CountyName, stateAbbreviation,
       SUM(CASE WHEN is_mapped = 1 THEN 1 ELSE 0 END) AS mapped_cnt,
       SUM(CASE WHEN is_mapped = 0 THEN 1 ELSE 0 END) AS unmapped_cnt,
       COUNT(*) AS total_cnt
FROM   #sel
GROUP BY cstitle_county_id, CountyName, stateAbbreviation
ORDER BY total_cnt DESC;


/* ----------------------------------------------------------------------------
   FILE_LINES — paste this single column into
   land_lease_producer/.../cstitle_lease_data_provider/test_guids_8708.txt
   (one 'cstitle_county_id,recordID' per line). 2,000 rows, ordered by county so
   each county's record IDs sit together.
   ---------------------------------------------------------------------------- */
SELECT CAST(cstitle_county_id AS varchar(12)) + ',' + CAST(recordID AS varchar(36)) AS file_line
FROM   #sel
ORDER BY cstitle_county_id, is_mapped, LeaseID DESC;


/* ----------------------------------------------------------------------------
   PINNED mapped lease for the clobber check — one guaranteed-published mapped
   lease whose df1 doc(s) we diff against an include_unmapped=False baseline.
   Record this LeaseID.
   ---------------------------------------------------------------------------- */
SELECT TOP (1) 'PINNED_MAPPED' AS which, LeaseID, recordID, cstitle_county_id, CountyName, stateAbbreviation
FROM   #sel
WHERE  is_mapped = 1
ORDER BY cstitle_county_id, LeaseID DESC;

DROP TABLE #sel;
DROP TABLE #base;
DROP TABLE #mapped_leases;
