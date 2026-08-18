/* ============================================================================
   LND-8655 — query_3: reconcile 7f84be77's current recordIsLease + instrument type
   Server: AUS2-PHX-DSQL01   DB: countyScansTitle

   Breakdown showed 100% of "RELEASE OF OIL GAS AND MINERAL LEASES" records are
   recordIsLease=0 (373/373, none at 1). query_1 (2026-08-10) recorded 7f84be77 as
   recordIsLease=1 for this instrument type. Check the live row to see which is true.
   ============================================================================ */
SELECT LOWER(r.recordID)        AS record_id,
       r.recordIsLease,
       r.InstrumentTypeFullId,
       f.InstrumentTypeFull,
       r.statusID
FROM [countyScansTitle].[dbo].[tblRecord] r
LEFT JOIN [countyScansTitle].[dbo].[tblLookupInstrumentTypeFull] f
     ON f.InstrumentTypeFullId = r.InstrumentTypeFullId
WHERE r.recordID = '7f84be77-3052-485b-a438-f2e17b5aa100';
