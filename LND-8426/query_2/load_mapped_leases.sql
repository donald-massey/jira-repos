/* ============================================================================
   LND-8426 — Load div1_leaseids.csv (4.8M distinct mapped LeaseIDs) into a
   staging table in countyScansTitle, for the Pass B split.

   Why a permanent table, not #temp: bcp connects in its own session, so it
   can't see another session's #mapped_leases. Load into dbo.LND8426_mapped_leases,
   run the split, then DROP it.

   The CSV: single column, header row 'LeaseID', UTF-8 BOM, CRLF line endings,
   ~4,806,976 data rows.
   ============================================================================ */

-- 1) create the staging table (run in countyScansTitle)
IF OBJECT_ID('dbo.LND8426_mapped_leases', 'U') IS NOT NULL
    DROP TABLE dbo.LND8426_mapped_leases;
CREATE TABLE dbo.LND8426_mapped_leases (LeaseID BIGINT NOT NULL);


/* 2) load it with bcp (client-side, streams to the remote server). Run in a
      terminal, NOT in SSMS. Windows auth shown (-T); swap for -U <user> -P <pw>
      if the CSTitle server uses SQL auth. Replace <CSTITLE_SERVER>.

      -F 2      skip the header row (also sidesteps the UTF-8 BOM)
      -r "\r\n" CRLF row terminator (file is Windows line endings)
      -c        character mode
      -b 100000 commit in 100k-row batches

bcp countyScansTitle.dbo.LND8426_mapped_leases in "C:\Users\donald.massey\PycharmProjects\jira-repos\LND-8426\div1_leaseids.csv" -S <CSTITLE_SERVER> -T -c -F 2 -r "\r\n" -b 100000
*/


-- 3) index after load (faster than loading into an indexed table)
CREATE CLUSTERED INDEX IX_LND8426_mapped_leases
    ON dbo.LND8426_mapped_leases (LeaseID);

-- sanity: expect ~4,806,976
SELECT COUNT(*) AS rows_loaded, COUNT(DISTINCT LeaseID) AS distinct_ids
FROM dbo.LND8426_mapped_leases;


/* 4) then run the Pass B split from LND-8426-mapping-split.sql, but replace
      the temp table with this staging table:
         JOIN/LEFT JOIN #mapped_leases ml   ->   LEFT JOIN dbo.LND8426_mapped_leases ml
      and skip the CREATE TABLE #mapped_leases step there. */

-- 5) cleanup when done
-- DROP TABLE dbo.LND8426_mapped_leases;