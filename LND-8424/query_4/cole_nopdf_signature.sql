/* ============================================================================
   LND-8424 — quantify the COLE reprocess batch (read-only)
   Signature (from the two MERCED records): a lease record that
     - has NO active land descriptions (tblLandDescription IsDeleted=0), AND
     - whose COLE run errored OCRErrorMessage = 'No pdf available'
       (IIE never ran: OCRs3Path NULL), AND
     - whose staged image was written by cs_updates AFTER that COLE run
       (image _ModifiedDateTime > COLE _OCRModifiedDateTime).
   These are records COLE "processed" before the PDF existed and never re-ran
   after cs_updates staged the file — reprocess candidates, not content gaps.

   Session on CSTitle (AUS2-PHX-DSQL01, countyScansTitle). CS_Digital via LINKTOPETL.
   Scoped to MERCED, CA — widen by editing the state/county filter in step 1.
   ============================================================================ */

/* 1) CSTitle-local candidate set: MERCED lease records, no land descriptions,
      image staged by cs_updates. */
IF OBJECT_ID('tempdb..#cand') IS NOT NULL DROP TABLE #cand;   -- temp table only
SELECT R.recordID,
       S.stateAbbreviation,
       C.CountyName,
       si.s3FilePath,
       si._ModifiedBy      AS image_ModifiedBy,
       si._ModifiedDateTime AS image_ModifiedDateTime
INTO #cand
FROM [countyScansTitle].[dbo].[tblRecord]          R
JOIN [countyScansTitle].[dbo].[tblLookupStates]    S  ON S.StateID  = R.stateID
JOIN [countyScansTitle].[dbo].[tblLookupCounties]  C  ON C.countyID = R.countyID
JOIN [countyScansTitle].[dbo].[tblS3Image]         si ON si.recordID = R.recordID
WHERE R.recordIsLease = 1
  AND R.statusID IN (4, 10, 16)
  AND S.stateAbbreviation = 'CA'
  AND C.CountyName = 'MERCED'
  AND si._ModifiedBy = 'cs_updates'
  AND NOT EXISTS (
        SELECT 1 FROM [countyScansTitle].[dbo].[tblLandDescription] L
        WHERE L.recordID = R.recordID AND L.IsDeleted = 0);

/* 2) Join to CS_Digital (via LINKTOPETL) and keep only the COLE 'No pdf available'
      records whose image is newer than the COLE run. */
IF OBJECT_ID('tempdb..#sig') IS NOT NULL DROP TABLE #sig;     -- temp table only
SELECT c.recordID,
       c.CountyName,
       x.package_id,
       l.OCRErrorMessage,
       l.IIEErrorMessage,
       l._OCRModifiedDateTime,
       l.OCRs3Path,
       c.image_ModifiedDateTime,
       DATEDIFF(day, l._OCRModifiedDateTime, c.image_ModifiedDateTime) AS days_image_newer_than_cole
INTO #sig
FROM #cand c
JOIN LINKTOPETL.CS_Digital.[dbo].[tblDimlXref]              x ON x.recordID   = c.recordID
JOIN LINKTOPETL.CS_Digital.[cole].[tblRecordProcessingLogs] l ON l.package_id = x.package_id
WHERE l.OCRErrorMessage = 'No pdf available'
  AND c.image_ModifiedDateTime > l._OCRModifiedDateTime;

/* 3) Summary count. */
SELECT CountyName,
       COUNT(*) AS reprocess_candidates
FROM #sig
GROUP BY CountyName;

/* 4) Detail list (package_ids to feed the reprocess). */
SELECT recordID, package_id, _OCRModifiedDateTime, image_ModifiedDateTime, days_image_newer_than_cole
FROM #sig
ORDER BY image_ModifiedDateTime DESC;
