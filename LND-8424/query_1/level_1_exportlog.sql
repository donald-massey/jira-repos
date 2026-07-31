/* ============================================================================
   LND-8424 — Level 1: ch-lease-exporter / IIF Lease Importer  (START HERE)
   MERCED, CA — RecordNumber 2024017111 (two RecordIDs, Div1 LeaseID 5067911)
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   A legal lease only reaches land-lease-producer if ch-lease-exporter matched the
   CSTitle record to a DIV1 LeaseID and wrote it to tblexportLog. Once ANY row
   exists for a recordID (even leaseID NULL), ch-lease-exporter never retries it.

   Server: AUS2-PHX-DSQL01   Database: countyScansTitle
   ============================================================================ */

/* ---- 1) tblexportLog status for both RecordIDs -----------------------------
   leaseID NOT NULL -> matched; proceed to query_2 (Level 2).
   leaseID NULL     -> IIF never created the DIV1 row / natural-key match failed.
                       Grab the zipName below, run iif_log_search.ps1, then step 2.
   no row           -> not yet exported. Confirm statusID IN (4,16) and that MERCED
                       is not on the ch-lease-exporter exclusion list.
   Note: volume + page both NULL means the Vol+PG fallback also fails on re-export. */
SELECT el.recordID,
       el.leaseID,
       el.exportDate,
       el.zipName,
       el._ModifiedDateTime,
       r.statusID,
       r.instrumentTypeID,
       r.fileDate,
       r.volume,
       r.page
FROM [countyScansTitle].[dbo].[tblexportLog] el
JOIN [countyScansTitle].[dbo].[tblRecord]    r ON r.recordID = el.recordID
WHERE el.recordID IN (
    '90c3e6e1-263c-4470-92c2-652f03092842',   -- file date 2024-07-20
    'c5d14542-c2ea-4a4a-8532-0936227ad2ec'    -- file date 2024-07-23
)
ORDER BY el.recordID, el._ModifiedDateTime;


/* ---- 2) Batch impact — blast radius of the zip -----------------------------
   Replace <ZIPNAME> with the zipName from step 1 (only if leaseID is NULL). */
SELECT el.zipName,
       COUNT(*)                                                 AS total_records,
       SUM(CASE WHEN el.leaseID IS NULL     THEN 1 ELSE 0 END)  AS null_lease_count,
       SUM(CASE WHEN el.leaseID IS NOT NULL THEN 1 ELSE 0 END)  AS matched_count
FROM [countyScansTitle].[dbo].[tblexportLog] el
WHERE el.zipName IN ('CH_08.31.2024.17.00_leases','CH_08.31.2024.17.01_leases')  -- c5d14542's NULL zips
GROUP BY el.zipName;


/* ---- 3) Remediation preview (read-only) ------------------------------------
   The runbook remediation to unlock a permanently-excluded batch is to remove its
   tblexportLog rows so ch-lease-exporter re-exports them. That removal is NOT
   scripted here — run it manually per the runbook only after:
     (a) compare_duplicate_records.sql confirms c5d14542 is a DISTINCT instrument
         (not a duplicate of 90c3e6e1 — a duplicate would import a second DIV1 lease), and
     (b) the batch-impact count (step 2) is reviewed — the same two zips carry other
         records that would also be unlocked.
   This preview just shows what the batch looks like. */
SELECT el.recordID, el.leaseID, el.exportDate, el.zipName, r.statusID
FROM [countyScansTitle].[dbo].[tblexportLog] el
JOIN [countyScansTitle].[dbo].[tblRecord]    r ON r.recordID = el.recordID
WHERE el.zipName IN ('CH_08.31.2024.17.00_leases','CH_08.31.2024.17.01_leases')  -- c5d14542's NULL zips
  AND r.statusID IN (4, 16);
