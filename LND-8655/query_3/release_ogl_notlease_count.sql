/* ============================================================================
   LND-8655 — query_3: how many records are recordIsLease=0 for instrument type
   "RELEASE OF OIL GAS AND MINERAL LEASES"
   Server: AUS2-PHX-DSQL01   DB: countyScansTitle

   InstrumentTypeFull is the text on tblLookupInstrumentTypeFull; join tblRecord
   to it and filter recordIsLease = 0.
   ============================================================================ */

/* ---- Count ---- */
SELECT COUNT(*) AS records_notlease
FROM [countyScansTitle].[dbo].[tblRecord] r
JOIN [countyScansTitle].[dbo].[tblLookupInstrumentTypeFull] f
     ON f.InstrumentTypeFullId = r.InstrumentTypeFullId
WHERE r.recordIsLease = 0
  AND f.InstrumentTypeFull = 'RELEASE OF OIL GAS AND MINERAL LEASES';


/* ---- Optional: recordIsLease breakdown for the same instrument type ---- */
SELECT r.recordIsLease,
       COUNT(*) AS record_count
FROM [countyScansTitle].[dbo].[tblRecord] r
JOIN [countyScansTitle].[dbo].[tblLookupInstrumentTypeFull] f
     ON f.InstrumentTypeFullId = r.InstrumentTypeFullId
WHERE f.InstrumentTypeFull = 'RELEASE OF OIL GAS AND MINERAL LEASES'
GROUP BY r.recordIsLease
ORDER BY r.recordIsLease;
