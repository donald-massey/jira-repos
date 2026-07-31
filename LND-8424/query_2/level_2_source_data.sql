/* ============================================================================
   LND-8424 — Level 2: source-data / mapping_id checks
   MERCED, CA — RecordNumber 2024017111, Div1 LeaseID 5067911
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Reach here only after Level 1 (query_1) shows leaseID NOT NULL.

   Glue's legal_lease writer drops any record with mapping_id IS NULL. mapping_id =
   land_descriptions[].legacy_mapping_id, sourced from DIV1 tblleaseAbstractMapping.

   MERCED is CSTitle-sourced (cstitle_lease_data_provider), but legacy_mapping_id is
   STILL inherited from DIV1: _enrich_land_descriptions_by_div1_legacy_fields() matches
   the CSTitle tblLandDescription rows to DIV1 land descriptions for LeaseID 5067911;
   no DIV1 mapping -> no legacy_mapping_id -> glue drops the record. So the gate is
   DIV1-side. CA is a base-path state (StateID NOT IN 91/102/93) — no parcel match.

   Session runs on CSTitle (AUS2-PHX-DSQL01, countyScansTitle). DIV1
   (V02PDIPRODDIV01.PROD.AUS, Div1_Daily) is reached via linked server LinktoDiv1Repl.
   ============================================================================ */

/* ---- A) DIV1 via linked server (run from the countyScansTitle session) ------
   Does LeaseID 5067911 have ANY abstract mapping? Zero rows -> no mapping_id ->
   glue drops it from legal_lease (the expected symptom for this ticket).
   OPENQUERY runs the join DIV1-side; LinktoDiv1Repl = CSTitle->DIV1 linked server. */
SELECT *
FROM OPENQUERY([LinktoDiv1Repl],
  'SELECT m.LeaseID, m.abstractID, m.mappingid AS legacy_mapping_id, m.parcelNum, a.StateID
   FROM Div1_Daily.dbo.tblleaseAbstractMapping m
   LEFT JOIN Div1_Daily.dbo.tblAbstract a ON a.AbstractID = m.abstractID
   WHERE m.LeaseID = 5067911');


/* ---- B) CSTitle (run on AUS2-PHX-DSQL01) -----------------------------------
   Base land descriptions for both RecordIDs — the rows the producer tries to enrich
   with DIV1 legacy_mapping_id. Zero rows -> nothing to match/publish. */
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
WHERE L.recordID IN (
    '90c3e6e1-263c-4470-92c2-652f03092842',
    'c5d14542-c2ea-4a4a-8532-0936227ad2ec'
)
  AND L.IsDeleted = 0;


/* ---- C) TblAddsFields parcel path — N/A for CA (base-path state). Skipped. */

/* ---- D) ES check -----------------------------------------------------------
   Is LeaseID 5067911 in legal_lease, or absent? DSL body in es_legal_lease_check.json.
   Cluster: cerebro "Elasticsearch DI Regulatory 6x Client". */
