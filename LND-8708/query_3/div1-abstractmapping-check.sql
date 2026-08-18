-- ES Q2 sample: all 10 docs have mapping_id populated — confirmed mapped, DIV1-native leases.
-- These are DIV1 LeaseIDs (ints), NOT CSTitle recordIDs (GUIDs) — do NOT join tblRecord.
-- county/state already come from the ES doc; everything else is in DIV1.
--
-- tblLegalLease.svgPolygonGroupDetailId links to tblSVGPolygonGroupDetail.groupId.
-- Non-null = polygon drawn in DIV1; null = nothing for landtracs-geom-update-spark to read
-- (source filter at land.landtracs-geom-update-spark.py:345 requires it NOT NULL).
--
-- Run on CSTitle server (aus2-dtf-pap01v.na.drillinginfo.com) — reaches DIV1 via LinktoDiv1Repl.

CREATE TABLE #target_leases (lease_id INT, county_state VARCHAR(64));

INSERT INTO #target_leases (lease_id, county_state) VALUES
(174305, 'EVANGELINE (LA)'),
(174414, 'EVANGELINE (LA)'),
(176027, 'SOMERVELL (TX)'),
(172470, 'JACK (TX)'),
(183193, 'MONTAGUE (TX)'),
(171755, 'VERMILION (LA)'),
(171791, 'VERMILION (LA)'),
(170085, 'IBERVILLE (LA)'),
(174359, 'EVANGELINE (LA)'),
(174404, 'EVANGELINE (LA)');

SELECT
    tl.lease_id,
    tl.county_state,
    m.mapping_count,
    m.sample_mapping_id,
    ll.svgPolygonGroupDetailId,
    CASE
        WHEN ll.LeaseID IS NULL                 THEN 'LEASE NOT IN DIV1 tblLegalLease'
        WHEN ISNULL(m.mapping_count, 0) = 0     THEN 'NO MAPPING'
        WHEN ll.svgPolygonGroupDetailId IS NULL THEN 'MAPPED — NO POLYGON IN DIV1 (never read by geom job)'
        ELSE                                         'MAPPED — POLYGON EXISTS (parse/pipeline gap)'
    END AS diagnosis
FROM #target_leases tl
LEFT JOIN (
    SELECT LeaseID, svgPolygonGroupDetailId
    FROM OPENQUERY([LinktoDiv1Repl],
        'SELECT LeaseID, svgPolygonGroupDetailId FROM div1_Daily.dbo.tblLegalLease')
) ll ON ll.LeaseID = tl.lease_id
LEFT JOIN (
    SELECT
        LeaseID,
        COUNT(mappingid) AS mapping_count,
        MAX(mappingid)   AS sample_mapping_id
    FROM OPENQUERY([LinktoDiv1Repl],
        'SELECT LeaseID, mappingid FROM div1_Daily.dbo.tblleaseAbstractMapping')
    GROUP BY LeaseID
) m ON m.LeaseID = tl.lease_id
ORDER BY tl.county_state, tl.lease_id;

DROP TABLE #target_leases;


SELECT *
FROM countyScansTitle.dbo.tblrecord r
JOIN countyScansTitle.dbo.tblexportlog l ON l.recordID = r.recordID
WHERE leaseID IN (174305,174359,174404,174414,170085,172470,183193,176027,171755,171791)