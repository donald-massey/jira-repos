/*
LND-8658 - Recent WV LegalLeases Not Published
Diagnostic query 4 (TOP / run first): evaluate images + land descriptions per record, then resolve
where each record stops in the pipeline.

Causal chain that must hold for a lease to reach the DS9 pres.legal_lease cache:
   image  ->  parsed land description (BriefLegal / abstract)  ->  tblAbstract + tblleaseAbstractMapping
          ->  mapping_id on the Kafka message  ->  survives kafka_to_adl.filter_records_without_mapping_id.

For WV, mapping_id comes ONLY from div1_get_additional_fields.sql (StateID in 91,102,93), which
reads tblleaseAbstractMapping. A WV lease with no abstract mapping has null mapping_id and is dropped
from DS9 (ES keeps it post LND-8708). This query shows, per affected record:
  - image presence (tblDimlXref package rows; the xlsx also carries storageFilePath, 'NONE' = no image),
  - CSTitle land-description rows (tbllandDescription, IsDeleted=0) and how many carry an AbstractName,
  - DIV1 abstract-mapping rows (the mapping_id source),
and gives a pipeline verdict.

Read-only. Run ON the countyScansTitle server (recordID tables local; LinktoDiv1Repl link to DIV1).
*/

DECLARE @rec TABLE (record_id NVARCHAR(50) PRIMARY KEY, county NVARCHAR(30));
INSERT INTO @rec (record_id, county) VALUES
    ('3d44cb45-f0e5-4097-b9de-93db99bf597c','Braxton'),
    ('386f3b84-92fc-4bd0-85ba-a7d8a025e30c','Preston'),
    ('71b85e2b-cdd3-4a64-9925-df9dcb698610','Preston'),
    ('141ae74f-49b0-11e9-a8af-005056b6bf7c','Preston'),   -- storageFilePath = NONE
    ('5635d98f-0236-11e9-a4d1-005056b6bf7c','Preston'),   -- storageFilePath = NONE
    ('47fd3773-7612-4ede-9de8-208513af6d7b','Randolph'),
    ('7c1984cb-341d-43ca-aabf-46ea6b04531c','Randolph'),  -- no Div1 LeaseID
    ('5ba5b619-92f1-4837-b2d2-858fa4847cf4','Randolph'),
    ('54e1a810-0b34-11e9-a911-00505681224b','Randolph'),
    ('348c7efa-88e4-11e9-9457-00505681224b','Randolph'),
    ('cdb6b257-a74b-49f8-b933-a36a2fdcbc0b','Upshur');

SELECT
    r.record_id,
    r.county,
    lease.lease_id,

    -- IMAGE evaluation
    (SELECT COUNT(*) FROM [dbo].[tblDimlXref] x
      WHERE LOWER(x.recordID) = r.record_id)                                  AS diml_package_count,

    -- LAND DESCRIPTION evaluation (CSTitle)
    (SELECT COUNT(*) FROM [dbo].[tbllandDescription] L
      WHERE LOWER(L.recordID) = r.record_id AND L.IsDeleted = 0)             AS cstitle_landdesc_count,
    (SELECT COUNT(*) FROM [dbo].[tbllandDescription] L
      WHERE LOWER(L.recordID) = r.record_id AND L.IsDeleted = 0
        AND NULLIF(LTRIM(RTRIM(L.AbstractName)), '') IS NOT NULL)            AS cstitle_landdesc_with_abstractname,

    -- MAPPING evaluation (DIV1 - the mapping_id source for WV via additional_fields)
    mapp.div1_abstract_mapping_count,

    -- PIPELINE VERDICT
    CASE
        WHEN lease.lease_id IS NULL
            THEN '1. no Div1 LeaseID -> excluded at producer (never reaches Kafka)'
        WHEN mapp.div1_abstract_mapping_count = 0
            THEN '2. zero abstract mapping -> null mapping_id -> dropped at DS9 (present in ES post-8708)'
        ELSE '3. has mapping -> should publish to DS9 (check watermark/query_1 if still absent)'
    END AS pipeline_verdict
FROM @rec r
LEFT JOIN [dbo].[tblRecord] R ON LOWER(R.recordID) = r.record_id
OUTER APPLY (
    SELECT MAX(el.LeaseID) AS lease_id
    FROM [dbo].[tblexportLog] el
    WHERE el.recordID = R.recordID
) lease
OUTER APPLY (
    SELECT COUNT(*) AS div1_abstract_mapping_count
    FROM [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblleaseAbstractMapping] m
    WHERE m.LeaseID = lease.lease_id
) mapp
ORDER BY r.county, r.record_id;
