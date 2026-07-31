/* ============================================================================
   LND-8425 — Level 1: ch-lease-exporter / IIF Lease Importer check (START HERE)
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Target record (MIAMI, KS):
     RecordID     = 68125b82-1ae2-4058-a46f-f3e46709e47b
     RecordNumber = 2025-03537
     File date    = 2025-08-29
     Div1_LeaseID = 5184347   <-- already populated on the ticket

   Because a Div1_LeaseID is already known, we EXPECT tblexportLog.leaseID to be
   NON-NULL (Level 1 passes) and the break to be at Level 2 — same profile as
   COLUMBIA, PA (4696618), not JEFFERSON, PA (leaseID = NULL / IIF race).
   Run on the CSTitle server (countyScansTitle).
   ============================================================================ */

-- 1) tblexportLog status for the record. Decision point:
--    leaseID IS NOT NULL -> ch-lease-exporter matched. Go to Level 2 (query_2).
--    leaseID IS NULL     -> IIF never created the DIV1 row / natural-key miss. See notes below.
--    no row              -> not yet exported; verify statusID IN (4,16) and the county
--                           is not on the ch-lease-exporter exclusion list.
SELECT l.recordID, l.leaseID, l.exportDate, l.zipName,
       r.recordNumber, r.recordIsLease, r.statusID, r.fileDate,
       c.CountyID, c.Div1CountyID, c.CountyName
FROM [countyScansTitle].[dbo].[tblexportLog] l
JOIN [countyScansTitle].[dbo].[tblRecord] r ON r.recordID = l.recordID
LEFT JOIN [countyScansTitle].[dbo].[tbllookupCounties] c ON c.CountyID = r.countyID
WHERE l.recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b';


-- 2) Sanity: does the record sit in the producer's candidate universe at all?
--    land-lease-producer selects recordIsLease = 1 AND statusID IN (4,10).
SELECT recordID, recordNumber, recordIsLease, statusID, fileDate, _ModifiedDateTime
FROM [countyScansTitle].[dbo].[tblRecord]
WHERE recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b';


/* ----------------------------------------------------------------------------
   IF leaseID IS NULL (unexpected here) — follow the runbook Level 1 branch:

   a) Note the zipName from query 1 and find the IIF week log:
        \\prod-loader05.prod.aus\logs\loaders\iif\iifLegalLeaseLoader.log.YYYY-WW
      (ISO week of exportDate). PowerShell:
        Select-String -Path "...\iifLegalLeaseLoader.log.<YYYY-WW>" -Pattern "<zipName>"
      Zip absent -> IIF never processed it (likely the 08:00-22:00 CST
      business-hours-sleep timing race; zip cleaned up before the 22:00 run).

   b) Quantify batch blast radius (query_1b below).

   c) REMEDIATION IS DOCUMENT-ONLY on this ticket (per decision): describe, do
      not execute. To unlock a missed batch, the tblexportLog rows for that
      zipName are removed (after verifying statusID IN (4,16) on tblRecord) so
      ch-lease-exporter re-exports them. Donald runs that statement manually.
   ---------------------------------------------------------------------------- */

-- 1b) Batch blast radius by zipName — replace <zipName> with the value from query 1.
--     Only run if leaseID came back NULL.
SELECT zipName,
       COUNT(*)                                            AS total_records,
       SUM(CASE WHEN leaseID IS NULL     THEN 1 ELSE 0 END) AS null_lease_count,
       SUM(CASE WHEN leaseID IS NOT NULL THEN 1 ELSE 0 END) AS matched_count
FROM [countyScansTitle].[dbo].[tblexportLog]
WHERE zipName = 'CH_09.22.2025.14.26_leases'
GROUP BY zipName;
