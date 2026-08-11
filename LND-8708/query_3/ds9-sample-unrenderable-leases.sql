-- Sample fully-unrenderable leases (EVERY mapping row has null geom_wkt + null lat/long)
-- to look up on the live site: confirm they appear in search/list with attributes but no
-- map pin and no error — the behavioral proof that publishing without geometry is tolerated.
--
-- These already exist in prod DS9 with null geometry today (113,655 such leases), so they
-- demonstrate the georendering service degrades gracefully rather than breaking.
--
-- Run on DS9 PROD: AUS2-DS9-PPL01.na.drillinginfo.com, DB = DS9.

USE [DS9];

WITH per_lease AS (
    SELECT
        lease_id,
        COUNT(*)                                              AS mapping_rows,
        SUM(CASE WHEN geom_wkt IS NOT NULL THEN 1 ELSE 0 END) AS rows_with_geom
    FROM [DS9].[pres].[legal_lease]
    GROUP BY lease_id
)
SELECT TOP 20
    ll.lease_id,
    ll.mapping_id,
    ll.record_number,
    ll.county_state,
    ll.grantor_name,
    ll.grantee_name,
    ll.latitude,
    ll.longitude,
    ll.geom_wkt
FROM per_lease pl
JOIN [DS9].[pres].[legal_lease] ll ON ll.lease_id = pl.lease_id
WHERE pl.rows_with_geom = 0          -- fully unrenderable
ORDER BY ll.lease_id, ll.mapping_id;
