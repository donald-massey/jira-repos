/* ============================================================================
   LND-8426 — Has COLE processed the COLUMBIA, PA image?

   Record: a688f5be-8530-4647-b73d-089c185c8262
           recordNumber 20190699, COLUMBIA, PA, Div1 LeaseID 4696618

   Theory to test: tblLandDescription is empty for this record not because the
   legal is unextractable, but because COLE simply hasn't processed the image
   yet (or errored). If so, the fix is a reprocess, not an upstream write-off.

   COLE data model (from LND-8093 cole_error_processing.sql):
     image        countyScansTitle.dbo.tblS3Image        (recordID -> s3FilePath)
     DIML xref    CS_Digital.dbo.tblDimlXref             (recordID -> package_id)
     COLE status  CS_Digital.cole.tblRecordProcessingLogs (package_id -> OCR/IIE)

   Run on the CSTitle server (CS_Digital is reachable there; adjust the 4-part
   [SERVER] prefix / linked-server name if your session is elsewhere).
   ============================================================================ */

DECLARE @recordID UNIQUEIDENTIFIER = 'a688f5be-8530-4647-b73d-089c185c8262';


/* ----------------------------------------------------------------------------
   1) Image exists?  Zero rows -> no image staged; COLE has nothing to consume
      and the gap is further upstream (ch-digital image load), not COLE.
   ---------------------------------------------------------------------------- */
SELECT s.recordID,
       s.s3FilePath,
       s.pageCount,
       s.fileSize,
       s._ModifiedDateTime,
       s._ModifiedBy
FROM countyScansTitle.dbo.tblS3Image s
WHERE s.recordID = @recordID;


/* ----------------------------------------------------------------------------
   2) DIML xref -> package_id.  COLE keys off package_id, so no xref row means
      the image was never registered with DIML and COLE never got a work item.
      (Column name may be package_id or document_dataset_id — verify against the
      schema; LND-8093 flagged this.)
   ---------------------------------------------------------------------------- */
SELECT x.recordID,
       x.package_id
FROM CS_Digital.dbo.tblDimlXref x
WHERE x.recordID = @recordID;


/* ----------------------------------------------------------------------------
   3) COLE processing log.  This is the answer:
        no rows                         -> COLE never processed it (just pending / dropped)
        row w/ OCRErrorMessage or
              IIEErrorMessage NOT NULL  -> COLE FAILED — reprocess candidate
        row, both error cols NULL       -> COLE ran clean but produced no legal
                                           -> real content gap, not a queue miss
   ---------------------------------------------------------------------------- */
SELECT l.package_id,
       l.inputDataset,
       l.OCRErrorMessage,
       l.IIEErrorMessage,
       l._OCRModifiedDateTime,
       l._IIEModifiedDateTime,
       l.OCRs3Path
FROM CS_Digital.dbo.tblDimlXref x
JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = x.package_id
WHERE x.recordID = @recordID;


/* ----------------------------------------------------------------------------
   4) Cross-check — did COLE actually write a land description back?
      Confirms query 3's verdict against the real output table. If (3) shows a
      clean run but this returns rows, the earlier "tblLandDescription = none"
      finding was stale; if (3) is empty AND this is empty, the record is simply
      unprocessed.
   ---------------------------------------------------------------------------- */
SELECT L.landDescriptionID,
       L.recordId,
       L.AbstractName,
       L.section,
       L.township,
       L.rangeOrBlock,
       L.IsDeleted
FROM countyScansTitle.dbo.tblLandDescription L
WHERE L.recordID = @recordID;


/* ----------------------------------------------------------------------------
   5) Staleness check — was the image modified AFTER COLE last processed it?
      COLE ran 2025-03-19; the image row was touched 2026-06-17 by cs_updates,
      15 months later. If that touch replaced the document (s3FilePath/content
      changed), COLE's output is stale against the current image and a reprocess
      IS justified. If it was only a metadata refresh (pageCount/fileSize), the
      content-gap verdict stands and the record is a legitimate write-off.

        image_newer_than_cole = 1  -> image changed after COLE ran; inspect what
                                      changed (s3FilePath below) — reprocess candidate
        image_newer_than_cole = 0  -> COLE saw the current image; content gap confirmed
   ---------------------------------------------------------------------------- */
SELECT s.recordID,
       s.s3FilePath,
       s.pageCount,
       s.fileSizeBytes,
       s._ModifiedDateTime            AS image_ModifiedDateTime,
       s._ModifiedBy                  AS image_ModifiedBy,
       l._OCRModifiedDateTime,
       l._IIEModifiedDateTime,
       CASE WHEN s._ModifiedDateTime >
                 COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime)
            THEN 1 ELSE 0 END         AS image_newer_than_cole,
       DATEDIFF(day,
                COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime),
                s._ModifiedDateTime)  AS days_image_newer_than_cole
FROM countyScansTitle.dbo.tblS3Image s
JOIN LINKTOPETL.CS_Digital.dbo.tblDimlXref x               ON x.recordID   = s.recordID
JOIN LINKTOPETL.CS_Digital.cole.tblRecordProcessingLogs l  ON l.package_id = x.package_id
WHERE s.recordID = @recordID;


/* ----------------------------------------------------------------------------
   6) Definitive staleness check — NOT SQL. Run against S3, not the DB.

      Q5 returned image_newer_than_cole=1 (455 days), but that only proves the
      tblS3Image ROW was touched, not that the PDF changed. s3FilePath is keyed
      on recordID so it can't move even if the file is overwritten in place, and
      cs_updates is a batch actor whose touch is just as likely a metadata
      refresh as a content replacement. The DB can't distinguish the two.

      The S3 object's own LastModified is the tie-breaker. Refresh AWS session
      creds first, then:

        aws s3api head-object \
          --bucket enverus-courthouse-prod-chd-plants \
          --key pa/columbia/a688/a688f5be-8530-4647-b73d-089c185c8262.pdf \
          --query '{LastModified:LastModified,ContentLength:ContentLength}'

      Interpretation (COLE OCR ran 2025-03-19; DB fileSizeBytes = 303276):
        LastModified AFTER  2025-03-19  OR  ContentLength <> 303276
            -> PDF genuinely replaced after COLE ran -> REPROCESS candidate
        LastModified BEFORE 2025-03-19  AND ContentLength =  303276
            -> 2026-06-17 DB touch was metadata-only; COLE saw the current file
            -> content gap CONFIRMED, legitimate write-off
   ---------------------------------------------------------------------------- */
