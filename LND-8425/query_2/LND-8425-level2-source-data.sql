/* ============================================================================
   LND-8425 — Level 2: land-lease-producer -> land-aws-glue source-data checks
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Run only after Level 1 (query_1) confirms tblexportLog.leaseID IS NOT NULL.

   Target: MIAMI, KS
     RecordID     = 68125b82-1ae2-4058-a46f-f3e46709e47b
     Div1_LeaseID = 5184347

   The glue legal_lease writer keeps only mapping_id IS NOT NULL. mapping_id
   (= DIV1 tblleaseAbstractMapping.mappingid) is the drop gate. These checks
   locate whether the record has land descriptions / an abstract mapping.

   KS-SPECIFIC: KS is NOT in the OH/WV/PA additional-fields group
   (StateID 91/102/93), so it uses the BASE land-description path
   (div1_get_land_descriptions.sql, WHERE StateID NOT IN (91,102,93)). The PA
   TblAddsFields parcel-number path does not apply — check_0 confirms this.
   Run DIV1 checks against V02PDIPRODDIV01.PROD.AUS (div1_Daily);
   CSTitle checks against countyScansTitle.
   ============================================================================ */


-- 0) [CSTitle] Confirm KS's StateID and that it is outside the OH/WV/PA group.
--    Expected: KS StateID NOT IN (91,102,93) -> base path applies, not parcel path.
SELECT StateID, stateAbbreviation
FROM [countyScansTitle].[dbo].[tblLookupStates]
WHERE stateAbbreviation = 'KS';


-- 1) [DIV1] Does the lease have ANY abstract mapping (no state filter)?
--    This is the mapping_id source. Zero rows here = record is dropped by glue.
SELECT m.LeaseID, m.abstractID, m.mappingid AS legacy_mapping_id, m.parcelNum,
       a.StateID, st.state_name
FROM [LinktoDiv1Repl].[div1_Daily].[dbo].[tblleaseAbstractMapping] m
LEFT JOIN [LinktoDiv1Repl].[div1_Daily].[dbo].[tblAbstract] a ON a.AbstractID = m.abstractID
LEFT JOIN [LinktoDiv1Repl].[div1_Daily].[dbo].[tblState]   st ON st.StateID   = a.StateID
WHERE m.LeaseID = 5184347;


-- 2) [CSTitle] Base land descriptions for the record (the KS path).
--    Populates legacy_mapping_id via DIV1; if empty AND check 1 empty ->
--    no legal description anywhere -> upstream courthouse extraction gap.
SELECT L.landDescriptionID, L.AbstractName, L.section, L.township,
       L.rangeOrBlock, L.survey, L.IsDeleted
FROM [countyScansTitle].[dbo].[tblRecord] R
JOIN [countyScansTitle].[dbo].[tblLandDescription] L ON R.recordID = L.recordID
WHERE R.recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b';


-- 3) [CSTitle] Record shell — confirm it exists and its publishable status.
SELECT recordID, recordNumber, statusID, recordIsLease, fileDate, countyID, stateID
FROM [countyScansTitle].[dbo].[tblRecord]
WHERE recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b';


/* ----------------------------------------------------------------------------
   Interpretation (runbook Level 2, step 5):
     * check 1 AND check 2 both empty -> upstream courthouse legal-extraction
       gap; the record was never given a legal description / abstract mapping.
       Pipeline (producer + glue) is behaving correctly. If recoverability is in
       question, follow the COLE processing check (query_4 pattern from LND-8426)
       to see whether a reprocess could ever produce a legal.
     * land descriptions present but no mapping_id -> chase the abstract mapping
       (base path for KS: tblLandDescription -> DIV1 tblAbstract join).
   ---------------------------------------------------------------------------- */
