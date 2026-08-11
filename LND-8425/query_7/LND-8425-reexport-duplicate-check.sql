/* ============================================================================
   LND-8425 — Does re-export create a duplicate DIV1 lease?  (empirical)

   Remediation step 2 deletes the tblexportLog row so ch-lease-exporter re-selects
   the re-keyed record and re-exports it → IIF re-imports. Open question: does IIF
   INSERT a new DIV1 lease (new LeaseID) or MATCH/backfill the existing one?

   tblexportLog is the ground truth: every export writes (recordID, leaseID,
   exportDate, zipName), and leaseID is the DIV1 LeaseID that match_new_leases()
   paired to the record after IIF import. So a recordID that was exported MORE THAN
   ONCE tells us what IIF did on the re-import:
     * 2+ DISTINCT non-null leaseIDs for one recordID -> IIF created a NEW lease
       each time -> re-export DOES duplicate. Confirm the concern.
     * exactly 1 distinct non-null leaseID (extra rows repeat it or are NULL)
       -> IIF matched the existing lease -> re-export does NOT duplicate.

   Read-only. Run on the CSTitle server (countyScansTitle).
   ============================================================================ */


-- 1) Headline: of all records exported more than once, how many kept ONE LeaseID
--    (backfill / no duplicate) vs got MULTIPLE (duplicate created)?
--    COUNT(DISTINCT leaseID) ignores NULLs, so (5184347, NULL) counts as 1.
WITH exp AS (
    SELECT recordID,
           COUNT(*)                AS export_rows,
           COUNT(DISTINCT leaseID) AS distinct_leaseids,
           COUNT(leaseID)          AS nonnull_leaseid_rows
    FROM [countyScansTitle].[dbo].[tblexportLog]
    GROUP BY recordID
    HAVING COUNT(*) > 1
)
SELECT
    CASE WHEN distinct_leaseids >= 2 THEN 'MULTIPLE LeaseIDs  -> re-export DUPLICATES'
         WHEN distinct_leaseids  = 1 THEN 'SAME LeaseID       -> backfill, NO duplicate'
         ELSE                              'NO non-null LeaseID (never matched)' END AS verdict,
    COUNT(*)             AS record_count,
    SUM(export_rows)     AS total_export_rows
FROM exp
GROUP BY
    CASE WHEN distinct_leaseids >= 2 THEN 'MULTIPLE LeaseIDs  -> re-export DUPLICATES'
         WHEN distinct_leaseids  = 1 THEN 'SAME LeaseID       -> backfill, NO duplicate'
         ELSE                              'NO non-null LeaseID (never matched)' END
ORDER BY record_count DESC;


-- 2) The smoking gun (if any): recordIDs that were assigned 2+ DISTINCT LeaseIDs
--    across exports — i.e. IIF made a duplicate lease. Empty result = no dup ever.
SELECT l.recordID, l.leaseID, l.exportDate, l.zipName
FROM [countyScansTitle].[dbo].[tblexportLog] l
JOIN (
    SELECT recordID
    FROM [countyScansTitle].[dbo].[tblexportLog]
    GROUP BY recordID
    HAVING COUNT(DISTINCT leaseID) >= 2
) d ON d.recordID = l.recordID
ORDER BY l.recordID, l.exportDate;


-- ============================================================================
-- REFINEMENT: steps 1-2 are polluted by manual/bulk jobs (LND-6732(2), LND-5774,
-- "LEGACY LEASE MAPPING", "LEGACY MAPPING EXPANSION ...") that inserted a second
-- tblexportLog row with a DIFFERENT LeaseID OUTSIDE the ch-lease-exporter -> IIF
-- path. Those are not organic re-exports. The remediation (delete tblexportLog
-- row -> exporter re-selects -> new CH_..._leases zip -> IIF) is organic-vs-organic,
-- so restrict to rows whose zipName is the exporter's own naming convention.
-- Pattern: 'CH_<date>_leases' e.g. CH_09.22.2025.14.26_leases  ([_] escapes the _).
-- ============================================================================

-- 4) Organic-only headline: records exported 2+ times BY THE EXPORTER — same LeaseID
--    (IIF backfilled, no duplicate) vs multiple (IIF inserted a new lease).
WITH organic AS (
    SELECT recordID, leaseID
    FROM [countyScansTitle].[dbo].[tblexportLog]
    WHERE zipName LIKE 'CH[_]%[_]leases'
),
exp AS (
    SELECT recordID,
           COUNT(*)                AS export_rows,
           COUNT(DISTINCT leaseID) AS distinct_leaseids
    FROM organic
    GROUP BY recordID
    HAVING COUNT(*) > 1
)
SELECT
    CASE WHEN distinct_leaseids >= 2 THEN 'MULTIPLE LeaseIDs  -> re-export DUPLICATES'
         WHEN distinct_leaseids  = 1 THEN 'SAME LeaseID       -> backfill, NO duplicate'
         ELSE                              'NO non-null LeaseID (never matched)' END AS verdict,
    COUNT(*) AS record_count
FROM exp
GROUP BY
    CASE WHEN distinct_leaseids >= 2 THEN 'MULTIPLE LeaseIDs  -> re-export DUPLICATES'
         WHEN distinct_leaseids  = 1 THEN 'SAME LeaseID       -> backfill, NO duplicate'
         ELSE                              'NO non-null LeaseID (never matched)' END
ORDER BY record_count DESC;


-- 5) Organic smoking gun: records that appear in 2+ CH exporter zips and got 2+
--    DISTINCT LeaseIDs. If EMPTY -> the exporter->IIF path has never duplicated a
--    lease on organic re-export -> the delete-tblexportLog + re-key plan is safe.
SELECT l.recordID, l.leaseID, l.exportDate, l.zipName
FROM [countyScansTitle].[dbo].[tblexportLog] l
JOIN (
    SELECT recordID
    FROM [countyScansTitle].[dbo].[tblexportLog]
    WHERE zipName LIKE 'CH[_]%[_]leases'
    GROUP BY recordID
    HAVING COUNT(DISTINCT leaseID) >= 2
) d ON d.recordID = l.recordID
WHERE l.zipName LIKE 'CH[_]%[_]leases'
ORDER BY l.recordID, l.exportDate;


-- 6) TRUE re-exports only — records in 2+ DISTINCT organic zips (strips the
--    single-export multi-lease noise that inflates step 5). For each, list every
--    (zip, exportDate, leaseID). Read it as: does a LATER zip introduce a leaseID
--    that the EARLIER zip did not have? If every record re-uses the same leaseID
--    set across its zips -> re-export re-matches the existing lease, no duplicate.
WITH organic AS (
    SELECT recordID, leaseID, zipName, exportDate
    FROM [countyScansTitle].[dbo].[tblexportLog]
    WHERE zipName LIKE 'CH[_]%[_]leases' AND leaseID IS NOT NULL
),
multi_zip AS (
    SELECT recordID
    FROM organic
    GROUP BY recordID
    HAVING COUNT(DISTINCT zipName) >= 2
)
SELECT o.recordID, o.zipName, o.exportDate, o.leaseID
FROM organic o
JOIN multi_zip m ON m.recordID = o.recordID
ORDER BY o.recordID, o.exportDate, o.leaseID;


-- 3) Sizing context — how much re-export history is in the table at all?
SELECT
    (SELECT COUNT(*)                 FROM [countyScansTitle].[dbo].[tblexportLog]) AS total_rows,
    (SELECT COUNT(DISTINCT recordID) FROM [countyScansTitle].[dbo].[tblexportLog]) AS distinct_records,
    (SELECT COUNT(*) FROM (
        SELECT recordID
        FROM [countyScansTitle].[dbo].[tblexportLog]
        GROUP BY recordID
        HAVING COUNT(*) > 1
     ) z)                                                                         AS records_exported_multiple_times;
