-- WRONG SOURCE — kept for the record. CS_Stage_Prod.dbo.Vw_County is an EOG-keying-scoped
-- view (Q2 returned only 'EOG_McMullen', SourceId 2), NOT the countyparish master the CHLDL
-- pipeline joins against. Use diagnose_county_parish_delta.py instead: it reads the actual
-- imported county_parish_ids Delta table (has CountyParishSourceName) from S3 in Databricks.
--
-- Why the 118 LND-8093 records are absent from every CHLDL courthouse index.
-- CHLDL gate (record_transforms.filter_records_by_product): a record reaches the index
-- for plant type X only if (1) its `source` matches X's rule AND (2) its county carries
-- X's SourceId in county_parish. CountyParishInfo comes from a LEFT JOIN on
--   StateProvinceAbbreviation = record.StateAbbreviation
--   AND lower(county name) = lower(record.CountyName)
-- No match => CountyParishInfo null => dropped from ALL indices regardless of source.
-- SourceId map: 2=abstractplant, 3=hostedplant, 4=enhancedclerk, 6=historicalplant, 8=chdplant.
-- Source: CS_Stage_Prod.dbo.Vw_County on AUS2-PHX-DSQL01.na.drillinginfo.com (SQL Server).
-- NOTE: this view exposes CountyParishName; the CHLDL pipeline actually joins on
-- CountyParishSourceName (its own countyparish DB view). Name is a close proxy but if a
-- county shows here yet is absent downstream, the raw SourceName spelling is the next check.

-- Q1) Replicate the pipeline join EXACTLY. join_status='NO JOIN MATCH' => every record for
--     that county is dropped on condition 2. Otherwise the SourceId column shows which
--     index(es) that county's records can reach.
WITH rec (StateAbbrev, CSTitleCountyName) AS (
    SELECT * FROM (VALUES
        ('LA','St. Landry'),   -- 105 absent
        ('TX','McMullen'),     -- 7 absent (12 present via enhancedclerk)
        ('TX','Guadalupe'),    -- present (chdplant) -- control
        ('ND','Cavalier'),     -- 2 absent
        ('KS','Decatur'),      -- 1 absent
        ('KS','Greeley'),      -- 1 absent
        ('UT','Morgan'),       -- 1 absent
        ('PA','Washington')    -- 1 absent
    ) v (StateAbbrev, CSTitleCountyName)
)
SELECT
    r.StateAbbrev,
    r.CSTitleCountyName,
    vc.CountyParishName,
    vc.SourceId,
    CASE WHEN vc.CountyParishId IS NULL THEN 'NO JOIN MATCH (dropped everywhere)'
         ELSE 'matched' END AS join_status
FROM rec r
LEFT JOIN CS_Stage_Prod.dbo.Vw_County vc
       ON vc.StateProvinceAbbreviation = r.StateAbbrev
      AND LOWER(vc.CountyParishName) = LOWER(r.CSTitleCountyName)
ORDER BY r.StateAbbrev, r.CSTitleCountyName, vc.SourceId;

-- Q2) Loose lookup (LIKE) — shows the ACTUAL spellings/SourceIds Vw_County holds for these
--     counties even when the exact join misses. If a county shows here but NOT as 'matched'
--     in Q1, the cause is a name-spelling mismatch (e.g. 'St. Landry' vs 'St Landry').
SELECT StateProvinceAbbreviation, CountyParishName, CountyParishId, SourceId
FROM CS_Stage_Prod.dbo.Vw_County
WHERE (StateProvinceAbbreviation = 'LA' AND CountyParishName LIKE '%andry%')
   OR (StateProvinceAbbreviation = 'TX' AND CountyParishName LIKE '%c%ullen%')
   OR (StateProvinceAbbreviation = 'TX' AND CountyParishName LIKE '%uadalupe%')
   OR (StateProvinceAbbreviation = 'ND' AND CountyParishName LIKE '%avalier%')
   OR (StateProvinceAbbreviation = 'KS' AND CountyParishName LIKE '%ecatur%')
   OR (StateProvinceAbbreviation = 'KS' AND CountyParishName LIKE '%reeley%')
   OR (StateProvinceAbbreviation = 'UT' AND CountyParishName LIKE '%organ%')
   OR (StateProvinceAbbreviation = 'PA' AND CountyParishName LIKE '%ashington%')
ORDER BY StateProvinceAbbreviation, CountyParishName, SourceId;
