-- LND-8452: cross-county / different-document correctness set (split off from LND-6796)
-- Identify the records behind one DIML package_id that disagree on county and/or document.
--
-- All tables are local to CS_Digital (no linked server). Default CI collation, so no
-- LOWER() in joins (stays sargable). Column casing follows the cs-digital-mfg loader's
-- own SQL (new_record_query.sql); verify against the schema if it has drifted.
--
-- HOW TO RUN: execute Section 0 (staging) FIRST, then run (a) / (b) / the COLE dataset
-- query in the SAME SSMS window — #affected_records is session-scoped. The expensive
-- xref<->record join runs ONCE in staging; the later queries read the small indexed
-- temp table in seconds. tempdb only — no schema change.
--
-- Every record surfaced here has a live tblRecord row (the staging JOIN is an INNER
-- JOIN), so this set is disjoint from the orphaned-xref cleanup and the duplicate-xref
-- dedupe, both of which key on recordIDs ABSENT from / duplicated in tblRecord.


/* ===========================================================================
   0. STAGING — run first. Pre-filter to package_ids with >1 record (a
      single-record package_id can't be cross-county or multi-document), then
      materialize the xref<->record join once. Doing only the JOIN here (no
      COUNT(DISTINCT)) avoids the wide-varchar distinct + tempdb spill that made
      the naive full-table query take ~22 minutes.
   =========================================================================== */
IF OBJECT_ID('tempdb..#affected_records') IS NOT NULL DROP TABLE #affected_records;

WITH multi_record AS (
    SELECT package_id
    FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY package_id
    HAVING COUNT(*) > 1
)
SELECT
    x.package_id,
    x.RecordID,
    r.CountyID,
    r.originalFileName,
    r.storageFilePath
INTO #affected_records
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN multi_record m                   ON m.package_id = x.package_id
JOIN [CS_Digital].[dbo].[tblRecord] r ON x.RecordID   = r.recordID;

CREATE CLUSTERED INDEX ix_affected_pkg ON #affected_records (package_id);


/* ---------------------------------------------------------------------------
   (a) DIFFERENT DOCUMENTS: package_ids whose records point to more than one DIML
       document. originalFileName = {'package_id','dataset_id'} (clerk_load.py);
       package_id is constant within the group, so >1 distinct originalFileName
       => >1 dataset_id => different underlying document.
       PROXY ONLY — a package can legitimately hold several datasets. Confirm a
       genuine byte difference in DIML (list_datasets -> root instrument_pdf,
       compare S3 size + ETag) before treating a package as truly different-doc.
       Expect ~668 package_ids.
   --------------------------------------------------------------------------- */
SELECT
    package_id,
    COUNT(DISTINCT originalFileName) AS distinct_documents,
    COUNT(*)                         AS record_count
FROM #affected_records
WHERE originalFileName IS NOT NULL
GROUP BY package_id
HAVING COUNT(DISTINCT originalFileName) > 1
ORDER BY distinct_documents DESC, record_count DESC;


/* ---------------------------------------------------------------------------
   (b) DIFFERENT COUNTY: package_ids whose records span more than one county.
       This is the headline multi-county issue. Expect ~2,192 package_ids.
   --------------------------------------------------------------------------- */
SELECT
    package_id,
    COUNT(DISTINCT CountyID) AS county_count,
    COUNT(*)                 AS record_count
FROM #affected_records
GROUP BY package_id
HAVING COUNT(DISTINCT CountyID) > 1
ORDER BY county_count DESC, record_count DESC;


/* ---------------------------------------------------------------------------
   COLE FIXED DATASET: every record behind a package_id flagged by (a) or (b),
   formatted for COLE's Fixed Dataset Selector (union of a + b). Columns match
   COLE's example CSV (required: recordID, countyName, stateAbbreviation,
   imageLocation; leaseID/fileDate/recordNumber optional). imageLocation mirrors
   COLE's own cs_title_and_chd_title_get_records.sql:
     LOWER(ISNULL(tblS3Image.s3FilePath, tblRecord.storageFilePath)).
   Export as CSV and upload one file to:
     s3://land-{dev,prod}/data/courthouse-ocr-legals-extractor/fixed_dataset/hardcoded_input/
   Expect ~4,838 distinct records (union of the 2,307 affected package_ids).

   DO NOT recompute the export as-built — see README "Fix path": IIE trusts the
   supplied county and OCR re-pulls the PDF from DIML by package_id, so the two
   data corrections (county + DIML document binding) plus the shared-package_id
   split must land first.
   --------------------------------------------------------------------------- */
WITH affected_pkgs AS (
    SELECT package_id
    FROM #affected_records
    GROUP BY package_id
    HAVING COUNT(DISTINCT CountyID) > 1
        OR COUNT(DISTINCT originalFileName) > 1
)
SELECT DISTINCT
    ar.RecordID                                      AS recordID,
    lc.CountyName                                    AS countyName,
    ls.StateAbbreviation                             AS stateAbbreviation,
    LOWER(ISNULL(s.s3FilePath, ar.storageFilePath))  AS imageLocation
FROM #affected_records ar
JOIN affected_pkgs a                                ON a.package_id = ar.package_id
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID  = ar.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates] ls   ON ls.StateID   = lc.StateID
LEFT JOIN [CS_Digital].[dbo].[tblS3Image] s         ON s.recordID   = ar.RecordID
ORDER BY recordID;
