/* ============================================================================
   LND-8655 — query_2: pipeline verification for the ONE actionable record
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Record : 7f84be77-3052-485b-a438-f2e17b5aa100  (Beauregard, LA — REOGL)
   DIV1   : LeaseID 5250310
   Export : exportLogID 11344487, exportDate 2026-04-21, statusID 4 (Published)

   Why this record: legal description (Exhibit A, S/T/R) IS present in the PDF but
   CSTitle tblLandDescription was never keyed. Empty land description => DIL carries
   no legal => IIF writes no tblleaseAbstractMapping => mapping_id NULL =>
   land-aws-glue filter_records_without_mapping_id() drops it from legal_lease.
   The other 23 records are document-type limitations (CO2-storage releases /
   offshore coordinate leases) — NOT rekeyable, not part of this verification.

   REMEDIATION SEQUENCE (run in order; steps 1 & 2 are manual, not scripted here):
     1. Keyers re-abstract the lease -> populate CSTitle tblLandDescription
        (section/township/rangeOrBlock/AbstractName/BriefLegal) for the recordID.
     2. Delete the tblexportLog row for this recordID so ch-lease-exporter's
        get_records() (which excludes anything already in tblexportLog) re-selects
        it. That DELETE is NOT written here per policy — run it manually in SSMS
        after confirming step 1 populated the land description (query A below).
        Target row: exportLogID 11344487 / recordID 7f84be77... .
     3. ch-lease-exporter re-exports -> IIF re-matches LeaseID 5250310 on the
        natural key (recordNumber/RecordDate/countyID — no new lease created) and
        writes tblleaseAbstractMapping.
     4. land-lease-producer picks up mapping_id -> glue publishes -> ES legal_lease.

   Run queries A/B on AUS2-PHX-DSQL01 (countyScansTitle). Query C reaches DIV1
   (V02PDIPRODDIV01.PROD.AUS / Div1_Daily) via linked server LinktoDiv1Repl.
   Query D (ES) is in es_legal_lease_check.json.
   ============================================================================ */

/* ---- A) GATE 1 — rekey landed: CSTitle tblLandDescription populated ----------
   BEFORE (query_1, 2026-08-10): 0 rows.
   PASS: >= 1 row with IsDeleted=0 and non-null section/township/rangeOrBlock
   (or AbstractName/BriefLegal). If still 0 rows -> keyers have not re-abstracted;
   stop, do not delete the tblexportLog row yet. */
SELECT L.landDescriptionID,
       LOWER(L.recordId) AS record_id,
       L.section,
       L.township,
       L.rangeOrBlock,
       L.survey,
       L.AbstractName,
       L.BriefLegal,
       L.IsDeleted
FROM [countyScansTitle].[dbo].[tblLandDescription] L
WHERE L.recordID = '7f84be77-3052-485b-a438-f2e17b5aa100';


/* ---- B) GATE 2 — re-export happened: tblexportLog re-selected the record ------
   BEFORE: single row, exportLogID 11344487, exportDate 2026-04-21, leaseID 5250310.
   After the manual DELETE + next ch-lease-exporter run, expect a NEW row with a
   fresh exportLogID/exportDate and leaseID 5250310 (same lease, re-matched on the
   natural key). leaseID NULL on the new row => IIF natural-key match failed —
   investigate before proceeding. */
SELECT el.exportLogID,
       el.recordID,
       el.leaseID,
       el.exportDate,
       el.zipName,
       el._ModifiedDateTime,
       r.statusID,
       r.recordNumber,
       r.fileDate,
       r.volume,
       r.page
FROM [countyScansTitle].[dbo].[tblexportLog] el
JOIN [countyScansTitle].[dbo].[tblRecord]    r ON r.recordID = el.recordID
WHERE el.recordID = '7f84be77-3052-485b-a438-f2e17b5aa100'
ORDER BY el._ModifiedDateTime;


/* ---- C) GATE 3 — mapping_id created: DIV1 tblleaseAbstractMapping -------------
   THE decisive gate. glue drops when mapping_id IS NULL; mapping_id source is
   DIV1 tblleaseAbstractMapping.mappingid for the LeaseID.
   BEFORE: 0 rows for LeaseID 5250310.
   PASS: >= 1 row -> legacy_mapping_id now exists -> record will publish.
   OPENQUERY runs the join DIV1-side over linked server LinktoDiv1Repl. */
SELECT *
FROM OPENQUERY([LinktoDiv1Repl],
  'SELECT m.LeaseID,
          m.abstractID,
          m.mappingid AS legacy_mapping_id,
          m.parcelNum,
          a.StateID
   FROM Div1_Daily.dbo.tblleaseAbstractMapping m
   LEFT JOIN Div1_Daily.dbo.tblAbstract a ON a.AbstractID = m.abstractID
   WHERE m.LeaseID = 5250310');
