-- Customer-impact scope: legal_lease geometry is grained by mapping_id. A lease with
-- multiple mappings still pins on the map if ANY mapping has geometry (e.g. lease 170085:
-- mapping 215609 has geom_wkt=POINT, 215610 is null → lease still renders via the sibling).
--
-- NOTE: the geometry-typed GEOM column is NULL table-wide; the point actually lives in the
-- geom_wkt (nvarchar) column + latitude/longitude. Testing GEOM reports everything as
-- unrenderable (artifact). Use geom_wkt / latitude as the real render source.
--
-- Splits pres.legal_lease leases into:
--   * RENDERS (>=1 mapping with geom_wkt)
--   * UNRENDERABLE (0 mappings with geom_wkt)  <- the real problem population
--
-- Run on DS9 PROD: AUS2-DS9-PPL01.na.drillinginfo.com, DB = DS9.

USE [DS9];

WITH per_lease AS (
    SELECT
        lease_id,
        COUNT(*)                                                AS mapping_rows,
        SUM(CASE WHEN geom_wkt IS NOT NULL THEN 1 ELSE 0 END)   AS rows_with_geom,
        SUM(CASE WHEN latitude IS NOT NULL THEN 1 ELSE 0 END)   AS rows_with_latlong
    FROM [DS9].[pres].[legal_lease]
    GROUP BY lease_id
)
SELECT
    CASE WHEN rows_with_geom = 0 THEN 'UNRENDERABLE (no geom_wkt on any mapping)'
         ELSE 'RENDERS (>=1 mapping has geom_wkt)' END AS render_status,
    COUNT(*)                  AS lease_count,
    SUM(mapping_rows)         AS mapping_row_count,
    SUM(rows_with_latlong)    AS mapping_rows_with_latlong
FROM per_lease
GROUP BY CASE WHEN rows_with_geom = 0 THEN 'UNRENDERABLE (no geom_wkt on any mapping)'
             ELSE 'RENDERS (>=1 mapping has geom_wkt)' END
ORDER BY lease_count DESC;