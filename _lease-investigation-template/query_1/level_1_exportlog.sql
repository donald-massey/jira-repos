/* ============================================================================
   {TICKET} — Level 1: ch-lease-exporter / IIF Lease Importer  (START HERE)
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   A legal lease only reaches land-lease-producer if ch-lease-exporter matched the
   CSTitle record to a DIV1 LeaseID and wrote it to tblexportLog. Once ANY row
   exists for a recordID (even leaseID NULL), ch-lease-exporter never retries it.

   Server: AUS2-PHX-DSQL01   Database: countyScansTitle
   ============================================================================ */

/* ---- 1) tblexportLog status ------------------------------------------------
   leaseID NOT NULL -> matched; proceed to query_2 (Level 2).
   leaseID NULL     -> IIF never created the DIV1 row / natural-key match failed.
                       Run iif_log_search.ps1, then step 2 (batch impact).
   no row           -> not yet exported. Confirm statusID IN (4,16) below and that
                       the county is not on the ch-lease-exporter exclusion list.
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
WHERE el.recordID IN ( {RECORDIDS} )
ORDER BY el.recordID, el._ModifiedDateTime;


/* ---- 2) Batch impact — blast radius of the zip -----------------------------
   If step 1 shows leaseID NULL, quantify how many records in the same zip are
   also NULL before remediating. */
SELECT el.zipName,
       COUNT(*)                                                 AS total_records,
       SUM(CASE WHEN el.leaseID IS NULL     THEN 1 ELSE 0 END)  AS null_lease_count,
       SUM(CASE WHEN el.leaseID IS NOT NULL THEN 1 ELSE 0 END)  AS matched_count
FROM [countyScansTitle].[dbo].[tblexportLog] el
WHERE el.zipName = '{ZIPNAME}'
GROUP BY el.zipName;


/* ---- 3) Remediation preview (read-only) ------------------------------------
   The runbook remediation to unlock a permanently-excluded batch is to remove its
   tblexportLog rows so ch-lease-exporter re-exports them. That removal is NOT
   scripted here — run it manually per the runbook, after verifying statusID IN (4,16)
   below and reviewing the batch-impact count (step 2). This preview is read-only. */
SELECT el.recordID, el.leaseID, el.exportDate, el.zipName, r.statusID
FROM [countyScansTitle].[dbo].[tblexportLog] el
JOIN [countyScansTitle].[dbo].[tblRecord]    r ON r.recordID = el.recordID
WHERE el.zipName = '{ZIPNAME}'
  AND r.statusID IN (4, 16);
