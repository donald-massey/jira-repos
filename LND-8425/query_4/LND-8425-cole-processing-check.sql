/* ============================================================================
   LND-8425 — Has COLE processed the MIAMI, KS image?  (recoverability check)
   Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284

   Record: 68125b82-1ae2-4058-a46f-f3e46709e47b
           recordNumber 2025-03537, MIAMI, KS, Div1 LeaseID 5184347

   Level 2 (query_2) proved tblLandDescription is EMPTY and there is no DIV1
   abstract mapping. This asks WHY the legal is missing:
     * COLE never processed the image (pending / dropped)   -> reprocess unblocks it
     * COLE errored (OCR/IIE error message)                 -> reprocess candidate
     * COLE ran clean but produced no legal                 -> real content gap, write-off

   COLE data model (from LND-8093 / LND-8426):
     image        countyScansTitle.dbo.tblS3Image           (recordID -> s3FilePath)
     DIML xref    CS_Digital.dbo.tblDimlXref                (recordID -> package_id)
     COLE status  CS_Digital.cole.tblRecordProcessingLogs   (package_id -> OCR/IIE)

   Run on the CSTitle server. CS_Digital is a separate database — if it is NOT
   on your session's instance, prefix the 3-part names with the linked server
   (LND-8426 query 5 used LINKTOPETL). The joins below use 3-part local names.
   ============================================================================ */

DECLARE @recordID UNIQUEIDENTIFIER = '68125b82-1ae2-4058-a46f-f3e46709e47b';


/* ----------------------------------------------------------------------------
   1) Image exists?  Zero rows -> no image staged; COLE has nothing to consume
      and the gap is further upstream (ch-digital image load), not COLE.
      Note fileSizeBytes / OCR date here — you need both for query 6 (S3 check).
   ---------------------------------------------------------------------------- */
SELECT s.recordID,
       s.s3FilePath,
       s.pageCount,
       s.fileSizeBytes,
       s._ModifiedDateTime,
       s._ModifiedBy
FROM [countyScansTitle].[dbo].[tblS3Image] s
WHERE s.recordID = @recordID;


/* ----------------------------------------------------------------------------
   2) DIML xref -> package_id.  COLE keys off package_id, so no xref row means
      the image was never registered with DIML and COLE never got a work item.
      (Column may be package_id or document_dataset_id — verify against schema.)
   ---------------------------------------------------------------------------- */
SELECT x.recordID,
       x.package_id
FROM [LINKTOPETL].[CS_Digital].[dbo].[tblDimlXref] x
WHERE x.recordID = @recordID;


/* ----------------------------------------------------------------------------
   3) COLE processing log.  This is the answer:
        no rows                         -> COLE never processed it (pending / dropped)
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
FROM [LINKTOPETL].[CS_Digital].[dbo].[tblDimlXref] x
JOIN [LINKTOPETL].[CS_Digital].[cole].[tblRecordProcessingLogs] l ON l.package_id = x.package_id
WHERE x.recordID = @recordID;


/* ----------------------------------------------------------------------------
   4) Cross-check — did COLE actually write a land description back?
      Confirms query 3's verdict against the real output table. If (3) shows a
      clean run but this returns rows, the "tblLandDescription = none" finding
      from query_2 was stale; if (3) is empty AND this is empty, unprocessed.
   ---------------------------------------------------------------------------- */
SELECT L.landDescriptionID,
       L.recordId,
       L.AbstractName,
       L.section,
       L.township,
       L.rangeOrBlock,
       L.IsDeleted
FROM [countyScansTitle].[dbo].[tblLandDescription] L
WHERE L.recordID = @recordID;


/* ----------------------------------------------------------------------------
   5) Staleness check — was the image modified AFTER COLE last processed it?
      If the image was replaced after COLE ran, COLE's output is stale against
      the current image and a reprocess IS justified. If only a metadata
      refresh, the content-gap verdict stands and the record is a write-off.

        image_newer_than_cole = 1  -> image row touched after COLE ran; inspect
                                      what changed (s3FilePath) — reprocess candidate
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
FROM [countyScansTitle].[dbo].[tblS3Image] s
JOIN [LINKTOPETL].[CS_Digital].[dbo].[tblDimlXref] x               ON x.recordID   = s.recordID
JOIN [LINKTOPETL].[CS_Digital].[cole].[tblRecordProcessingLogs] l  ON l.package_id = x.package_id
WHERE s.recordID = @recordID;


/* ----------------------------------------------------------------------------
   6) Definitive staleness check — NOT SQL. Run against S3, not the DB.

      Q5's image_newer_than_cole flag only proves the tblS3Image ROW was touched,
      not that the PDF changed. s3FilePath is keyed on recordID so it can't move
      even if the file is overwritten in place. The S3 object's own LastModified
      is the tie-breaker. Refresh AWS session creds first, then (substitute
      <fileSizeBytes> and <OCR_date> from queries 1 and 3):

        aws s3api head-object \
          --bucket enverus-courthouse-prod-chd-plants \
          --key ks/miami/6812/68125b82-1ae2-4058-a46f-f3e46709e47b.pdf \
          --query '{LastModified:LastModified,ContentLength:ContentLength}'

      Interpretation:
        LastModified AFTER  <OCR_date>  OR  ContentLength <> <fileSizeBytes>
            -> PDF genuinely replaced after COLE ran -> REPROCESS candidate
        LastModified BEFORE <OCR_date>  AND ContentLength =  <fileSizeBytes>
            -> DB touch was metadata-only; COLE saw the current file
            -> content gap CONFIRMED, legitimate write-off
   ---------------------------------------------------------------------------- */