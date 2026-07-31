/* ============================================================================
   LND-8424 — Level 2 follow-up: has COLE processed the MERCED image(s)?
   MERCED, CA — RecordNumber 2024017111 (two RecordIDs)
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Only relevant if query_2 shows the legal description itself is missing. Splits:
     no COLE row                       -> never processed (pending / dropped)
     row w/ OCR or IIE error NOT NULL  -> COLE FAILED -> reprocess candidate
     row, both error cols NULL         -> COLE ran clean -> content/document gap
     image _ModifiedDateTime > COLE    -> image replaced after COLE ran -> reprocess candidate

   COLE data model:
     image      countyScansTitle.dbo.tblS3Image                    (recordID -> s3FilePath)
     DIML xref  LINKTOPETL.CS_Digital.dbo.tblDimlXref              (recordID -> package_id)
     COLE log   LINKTOPETL.CS_Digital.cole.tblRecordProcessingLogs (package_id -> OCR/IIE)

   Run on the CSTitle server (session is countyScansTitle-majority); CS_Digital is
   reached via the LINKTOPETL linked server.
   ============================================================================ */

DECLARE @records TABLE (recordID UNIQUEIDENTIFIER);
INSERT INTO @records (recordID) VALUES
    ('90c3e6e1-263c-4470-92c2-652f03092842'),   -- file date 2024-07-20
    ('c5d14542-c2ea-4a4a-8532-0936227ad2ec')    -- file date 2024-07-23
;

/* 1) Image staged? Zero rows -> gap is upstream of COLE (ch-digital image load). */
SELECT s.recordID, s.s3FilePath, s.pageCount, s.fileSizeBytes, s._ModifiedDateTime, s._ModifiedBy
FROM [countyScansTitle].[dbo].[tblS3Image] s
JOIN @records rec ON rec.recordID = s.recordID;

/* 2) DIML xref -> package_id (COLE keys off package_id). */
SELECT x.recordID, x.package_id
FROM LINKTOPETL.CS_Digital.[dbo].[tblDimlXref] x
JOIN @records rec ON rec.recordID = x.recordID;

/* 3) COLE processing log — the verdict (see header). */
SELECT x.recordID, l.package_id, l.inputDataset, l.OCRErrorMessage, l.IIEErrorMessage,
       l._OCRModifiedDateTime, l._IIEModifiedDateTime, l.OCRs3Path
FROM LINKTOPETL.CS_Digital.[dbo].[tblDimlXref] x
JOIN LINKTOPETL.CS_Digital.[cole].[tblRecordProcessingLogs] l ON l.package_id = x.package_id
JOIN @records rec ON rec.recordID = x.recordID;

/* 4) Cross-check — did COLE write a land description back? (vs query_2 B) */
SELECT L.landDescriptionID, L.recordId, L.AbstractName, L.section, L.township, L.rangeOrBlock, L.IsDeleted
FROM [countyScansTitle].[dbo].[tblLandDescription] L
JOIN @records rec ON rec.recordID = L.recordID;

/* 5) Staleness — was the image modified AFTER COLE last ran? (reprocess trigger) */
SELECT s.recordID, s.s3FilePath, s.pageCount, s.fileSizeBytes,
       s._ModifiedDateTime AS image_ModifiedDateTime, s._ModifiedBy AS image_ModifiedBy,
       l._OCRModifiedDateTime, l._IIEModifiedDateTime,
       CASE WHEN s._ModifiedDateTime > COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime)
            THEN 1 ELSE 0 END AS image_newer_than_cole,
       DATEDIFF(day, COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime), s._ModifiedDateTime)
            AS days_image_newer_than_cole
FROM [countyScansTitle].[dbo].[tblS3Image] s
JOIN LINKTOPETL.CS_Digital.[dbo].[tblDimlXref] x               ON x.recordID   = s.recordID
JOIN LINKTOPETL.CS_Digital.[cole].[tblRecordProcessingLogs] l  ON l.package_id = x.package_id
JOIN @records rec ON rec.recordID = s.recordID;
