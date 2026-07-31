/* ============================================================================
   {TICKET} — Level 2: source-data / mapping_id checks
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Reach here only after Level 1 (query_1) shows leaseID NOT NULL.

   Glue's legal_lease writer (ElasticSearch6Cache) ends with
   filter_records_without_mapping_id() = WHERE mapping_id IS NOT NULL.
   mapping_id = land_descriptions[].legacy_mapping_id, sourced from DIV1
   tblleaseAbstractMapping.mappingid.

   CSTitle-sourced counties (CA etc.): legacy_mapping_id is STILL inherited from
   DIV1. cstitle_lease_data_provider._enrich_land_descriptions_by_div1_legacy_fields()
   matches CSTitle tblLandDescription rows to DIV1 land descriptions for the same
   LeaseID; no DIV1 mapping -> no legacy_mapping_id -> glue drops the record.

   Session runs on CSTitle (AUS2-PHX-DSQL01, countyScansTitle). DIV1
   (V02PDIPRODDIV01.PROD.AUS, Div1_Daily) is reached via linked server {LINK}.
   ============================================================================ */

/* ---- A) DIV1 via linked server (run from the countyScansTitle session) ------
   Does the LeaseID have ANY abstract mapping? This is the mapping_id source.
   Zero rows -> no mapping_id -> glue drops the record from legal_lease.
   OPENQUERY runs the join DIV1-side; {LINK} = CSTitle->DIV1 linked server (LinktoDiv1Repl). */
SELECT *
FROM OPENQUERY([{LINK}],
  'SELECT m.LeaseID, m.abstractID, m.mappingid AS legacy_mapping_id, m.parcelNum, a.StateID
   FROM Div1_Daily.dbo.tblleaseAbstractMapping m
   LEFT JOIN Div1_Daily.dbo.tblAbstract a ON a.AbstractID = m.abstractID
   WHERE m.LeaseID IN ( {LEASEIDS} )');


/* ---- B) CSTitle (run on AUS2-PHX-DSQL01) -----------------------------------
   Base land descriptions for the record(s) — the rows the producer tries to
   enrich with DIV1 legacy_mapping_id. Zero rows -> nothing to match/publish.
   (IsDeleted = 0 mirrors cstitle_get_land_descriptions.sql.) */
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
WHERE L.recordID IN ( {RECORDIDS} )
  AND L.IsDeleted = 0;


/* ---- C) OH/WV/PA ONLY: additional-fields parcel path -----------------------
   SKIP for base-path states (CA and most). For StateID 91/102/93 the mapping_id
   is matched on parcel number via TblAddsFields. Uncomment only for OH/WV/PA. */
-- SELECT recordId, Is_Pennsylvania, Pennsylvania_parcelNumber, Pennsylvania_muniName,
--        Is_Ohio, ohio_parcelNumber, Is_WestVirginia, WestVirginia_parcelNumber
-- FROM [countyScansTitle].[dbo].[TblAddsFields]
-- WHERE recordID IN ( {RECORDIDS} );

/* ---- D) ES check -----------------------------------------------------------
   Confirm whether the LeaseID is absent from legal_lease or present at an older
   version. DSL query body in es_legal_lease_check.json.
   Cluster: cerebro "Elasticsearch DI Regulatory 6x Client". */
