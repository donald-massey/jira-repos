/*
LND-8658 - Recent WV LegalLeases Not Published
Diagnostic query 1: selection-eligibility + watermark check.

Replays the static WHERE filters of cstitle_get_modified_instrument_ids.sql for the 15 affected
export-log rows (11 distinct recordIDs), with the modified-date OR-block removed, and exposes:
  - each filter gate as a pass/fail flag,
  - the current per-county watermark (LastProcessedDateLandLeaseProducer),
  - the record / exportLog / Div1-polygon modified timestamps,
  - whether every timestamp is BEHIND the watermark (i.e. stranded).

Read-only. Run against the CSTitle (countyScansTitle) database in SSMS.

Interpretation:
  - passes_all_static_filters = 0  -> excluded by a filter regardless of watermark
      (expect Randolph 7c1984cb... to fail on passes_leaseid_notnull).
  - passes_all_static_filters = 1 AND stranded_behind_watermark = 1
      -> eligible but never re-selected; watermark stranding is the cause.
  - passes_all_static_filters = 1 AND stranded_behind_watermark = 0
      -> would be selected today; failure is downstream (dropped during enrichment/publish).
*/

DECLARE @recordIds TABLE (recordId NVARCHAR(50) PRIMARY KEY);
INSERT INTO @recordIds (recordId) VALUES
    ('3d44cb45-f0e5-4097-b9de-93db99bf597c'),  -- Braxton
    ('386f3b84-92fc-4bd0-85ba-a7d8a025e30c'),  -- Preston
    ('71b85e2b-cdd3-4a64-9925-df9dcb698610'),  -- Preston
    ('141ae74f-49b0-11e9-a8af-005056b6bf7c'),  -- Preston
    ('5635d98f-0236-11e9-a4d1-005056b6bf7c'),  -- Preston
    ('47fd3773-7612-4ede-9de8-208513af6d7b'),  -- Randolph
    ('7c1984cb-341d-43ca-aabf-46ea6b04531c'),  -- Randolph (null Div1_LeaseID)
    ('5ba5b619-92f1-4837-b2d2-858fa4847cf4'),  -- Randolph
    ('54e1a810-0b34-11e9-a911-00505681224b'),  -- Randolph
    ('348c7efa-88e4-11e9-9457-00505681224b'),  -- Randolph
    ('cdb6b257-a74b-49f8-b933-a36a2fdcbc0b');  -- Upshur

SELECT
    LOWER(R.recordId)                               AS record_id,
    R.CountyID                                      AS county_id,
    R.StatusID                                      AS status_id,
    R.instrumentTypeID                              AS instrument_type_id,
    R.fileDate                                      AS file_date,
    el.exportLogID                                  AS export_log_id,
    el.LeaseID                                      AS lease_id,
    tl.LeaseID                                      AS div1_lease_id_present,
    tl.svgPolygonGroupDetailId                      AS svg_group_id,
    R._ModifiedDateTime                             AS record_modified,
    el._ModifiedDateTime                            AS export_modified,
    A.ModifiedTimestamp                             AS alias_map_modified,
    tspgd.updated                                   AS polygon_updated,
    DL.LastProcessedDateLandLeaseProducer           AS county_watermark,

    -- static filter gates from cstitle_get_modified_instrument_ids.sql
    CASE WHEN R.StatusID IN (4,10,16) THEN 1 ELSE 0 END                     AS passes_status,
    CASE WHEN R.instrumentTypeID NOT IN ('ASN','MD') THEN 1 ELSE 0 END      AS passes_type,
    CASE WHEN R.fileDate IS NOT NULL THEN 1 ELSE 0 END                      AS passes_filedate,
    CASE WHEN el.LeaseID IS NOT NULL THEN 1 ELSE 0 END                      AS passes_leaseid_notnull,
    CASE WHEN R.StatusID IN (4,10,16)
              AND R.instrumentTypeID NOT IN ('ASN','MD')
              AND R.fileDate IS NOT NULL
              AND el.LeaseID IS NOT NULL
         THEN 1 ELSE 0 END                                                  AS passes_all_static_filters,

    -- stranded = every modified timestamp is strictly before the county watermark
    CASE WHEN DL.LastProcessedDateLandLeaseProducer IS NOT NULL
              AND ISNULL(R._ModifiedDateTime,  '1900-01-01') <  DL.LastProcessedDateLandLeaseProducer
              AND ISNULL(el._ModifiedDateTime, '1900-01-01') <  DL.LastProcessedDateLandLeaseProducer
              AND ISNULL(A.ModifiedTimestamp,  '1900-01-01') <  DL.LastProcessedDateLandLeaseProducer
              AND ISNULL(tspgd.updated,        '1900-01-01') <  DL.LastProcessedDateLandLeaseProducer
         THEN 1 ELSE 0 END                                                  AS stranded_behind_watermark
FROM [dbo].[tblrecord] AS R
INNER JOIN @recordIds AS ids ON ids.recordId = LOWER(R.recordId)
LEFT JOIN [dbo].[tblexportLog] AS el ON el.recordID = R.recordID
LEFT JOIN Assignments.legal_lease_mapping A ON A.lease_id = el.LeaseID
LEFT OUTER JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblLegalLease] tl
    ON tl.LeaseID = el.LeaseID
LEFT OUTER JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblSVGPolygonGroupDetail] tspgd
    ON tspgd.groupID = tl.svgPolygonGroupDetailId
LEFT JOIN [dbo].[tblDataLoadersPerCounty] DL ON DL.CountyID = R.CountyID
ORDER BY R.CountyID, record_id, export_log_id;
