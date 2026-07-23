/* ============================================================================
   LND-8426 — ch-lease-exporter match investigation
   Record: 46e238a6-4e63-4f1e-95bf-916083355f24 (Jefferson, PA)
           recordNumber = 2023-004291, statusID = 4, leaseID = NULL in tblexportLog

   ch-lease-exporter already wrote a NULL leaseID row for this record, so it
   will never retry it. These queries identify why it missed the first time.

   Matching logic (queries.py:198-203):
     Strategy A (recordNumber != 'NA'): RecordNumber + RecordDate + CountyID
     Strategy B (recordNumber == 'NA'): Vol + PG + RecordDate + CountyID
   CountyID is converted via countyScansTitle.dbo.tbllookupCounties.Div1CountyID.
   DIV1 is queried with: created >= DATEADD(week, -1, load_stamp)
   ============================================================================ */


-- 1) CSTitle record — verify natural key values ch-lease-exporter would have used
SELECT recordID, recordNumber, RecordDate, volume, page, countyID, statusID, fileDate
FROM countyScansTitle.dbo.tblRecord
WHERE recordID = '46e238a6-4e63-4f1e-95bf-916083355f24';


-- 2) tblexportLog — when did ch-lease-exporter process this record?
--    exportDate is the load_stamp used in the 1-week DIV1 query window.
SELECT recordID, leaseID, exportDate, zipName
FROM countyScansTitle.dbo.tblexportLog
WHERE recordID = '46e238a6-4e63-4f1e-95bf-916083355f24';


-- 3) County mapping — what Div1CountyID does Jefferson, PA resolve to?
SELECT lc.CountyID, lc.Div1CountyID, lc.CountyName
FROM countyScansTitle.dbo.tbllookupCounties lc
WHERE lc.CountyID = (
    SELECT countyID
    FROM countyScansTitle.dbo.tblRecord
    WHERE recordID = '46e238a6-4e63-4f1e-95bf-916083355f24'
);


-- 4) DIV1 — does a tblLegalLease row exist for this RecordNumber?
--    Use LIKE to catch format variants (dashes stripped, leading zeros, etc.)
SELECT LeaseID, RecordNumber, RecordDate, Vol, PG, CountyID, created
FROM LinktoDiv1Repl.div1_daily.dbo.tblLegalLease
WHERE RecordNumber LIKE '%2023%004291%'
   OR RecordNumber = '2023-004291';


-- 5) DIV1 — if a row exists, check whether it fell inside the 1-week match window.
--    Replace <exportDate> with the exportDate value from query 2.
--    A row created before DATEADD(week, -1, exportDate) would have been invisible.
SELECT LeaseID, RecordNumber, RecordDate, CountyID, created,
       DATEADD(week, -1, '<exportDate>') AS window_start,
       CASE WHEN created >= DATEADD(week, -1, '<exportDate>')
            THEN 'IN WINDOW' ELSE 'OUTSIDE WINDOW' END AS match_window_status
FROM LinktoDiv1Repl.div1_daily.dbo.tblLegalLease
WHERE RecordNumber LIKE '%2023%004291%'
   OR RecordNumber = '2023-004291';


/* ----------------------------------------------------------------------------
   If query 4 returns a row:
     - Compare RecordNumber exact string vs CSTitle recordNumber
     - Compare RecordDate vs CSTitle RecordDate
     - Compare CountyID after mapping (query 3's Div1CountyID should equal DIV1's CountyID)
     - Check query 5 for window status

   If query 4 returns no rows:
     - The DIL was never imported into DIV1 by the IIF Lease Importer
     - Resolution: re-export the record (requires deleting the tblexportLog row first)
       DELETE FROM countyScansTitle.dbo.tblexportLog
       WHERE recordID = '46e238a6-4e63-4f1e-95bf-916083355f24'
       -- ch-lease-exporter will pick it up on next run if statusID IN (4,16)
   ---------------------------------------------------------------------------- */


  SELECT COUNT(*) AS record_count                                                                                                                           
  FROM countyScansTitle.dbo.tblexportLog                                                                                                                    
  WHERE zipName = 'CH_02.14.2024.08.41_leases';                                                                                                             
                                                                                                                                                            
  -- And to confirm they all landed as NULL (no IIF match):                                                                                                    
                                                                                                                                                            
  SELECT leaseID,                                                                                                                                           
         COUNT(*) AS cnt                                                                                                                                    
  FROM countyScansTitle.dbo.tblexportLog                                                                                                                    
  WHERE zipName = 'CH_02.14.2024.08.41_leases'                                                                                                              
  GROUP BY leaseID;


SELECT el.recordID, el.leaseID, el.exportDate, el.zipName, r.statusID
FROM countyScansTitle.dbo.tblexportLog el
JOIN countyScansTitle.dbo.tblRecord r ON r.recordID = el.recordID
WHERE el.recordID IN (
    '97820b78-78c3-11eb-87ba-00505681224b',  -- 202100502  2021-02-05
    'a993c242-c03d-11eb-abaa-00505681224b',  -- 202101869  2021-05-10
    '6109278c-221e-4a4c-b116-26dc42aded3c',  -- 202103826  2021-09-07
    'bf4f0a7e-80cb-11ec-babc-00505681224b',  -- 202105379  2021-12-28
    'cdfc6cc8-96cb-11ec-a054-00505681224b',  -- 202200403  2022-01-31
    '17a9fb26-acc4-11ec-8364-00505681224b',  -- 202200951  2022-03-14
    '68479647-ee74-402f-ba35-48c97a8f027c',  -- 202300916  2023-03-24
    '6f292243-fa73-4548-8062-41dad64324d0',  -- 202403237  2024-10-08
    'bd096468-d346-4c93-97a1-e5c64296125a',  -- 202403733  2024-11-08
    'b6d7d6d9-8b83-4cc4-851e-59e7d4a7d80c'   -- 202502353  2025-07-29
);