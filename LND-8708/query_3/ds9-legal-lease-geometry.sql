-- What does DS9 pres.legal_lease hold for lease 170085 (Iberville LA), and how did the
-- georendering service get a point (30.31540347, -91.30304092) when legal_lease ES has
-- null location/location_shape and DIV1 has null svgPolygonGroupDetailId?
--
-- Hypothesis: DS9Cache applies its own spatial enrichment (basin/play + WKT join) that the
-- producer/ES path does not, so DS9 may carry geometry the ES doc lacks.
--
-- Run on DS9 server. PROD: AUS2-DS9-PPL01.na.drillinginfo.com  (DEV: AUS2-DS9-DPL01), DB = DS9.
-- Table per land-aws-glue DS9Cache: pres.legal_lease (grain = mapping_id).

USE [DS9];

-- STEP 0: confirm column names (geometry/location/lat-long/mapping columns), then comment out
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'pres' AND TABLE_NAME = 'legal_lease'
ORDER BY ORDINAL_POSITION;

-- STEP 1: pull the rows for this lease (expect 2 rows — mapping_id 215610 + the 2nd mapping)
-- Adjust the selected geometry columns once STEP 0 reveals the real names
-- (candidates: location, location_shape, geom, shape, latitude, longitude, geom_wkt).
SELECT *
FROM [DS9].[pres].[legal_lease]
WHERE lease_id = 170085;
