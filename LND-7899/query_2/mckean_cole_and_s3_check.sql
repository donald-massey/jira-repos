-- LND-7899: McKean, PA — COLE processing status and S3 image paths
-- Run on countyScansTitle. CS_Digital is reachable via the LINKTOPETL linked server.
--
-- Interpretation:
--   tblS3Image empty          -> no image staged; COLE has nothing to process (upstream gap)
--   tblDimlXref empty         -> image never registered with DIML; COLE never got a work item
--   tblRecordProcessingLogs   -> no rows = never processed; error cols populated = COLE failed
--   Both errors NULL          -> COLE ran clean but no legal extracted (content gap, not a queue miss)

USE countyScansTitle;


-- 1. S3 image paths — confirm images exist and get the S3 keys for manual review
SELECT
    s.recordID,
    s.s3FilePath,
    s.pageCount,
    s.fileSize,
    s._ModifiedDateTime,
    s._ModifiedBy
FROM dbo.tblS3Image s
WHERE s.recordID IN (
    '97820b78-78c3-11eb-87ba-00505681224b',
    'a993c242-c03d-11eb-abaa-00505681224b',
    '6109278c-221e-4a4c-b116-26dc42aded3c',
    'bf4f0a7e-80cb-11ec-babc-00505681224b',
    'cdfc6cc8-96cb-11ec-a054-00505681224b',
    '17a9fb26-acc4-11ec-8364-00505681224b',
    '68479647-ee74-402f-ba35-48c97a8f027c',
    '6f292243-fa73-4548-8062-41dad64324d0',
    'bd096468-d346-4c93-97a1-e5c64296125a',
    'b6d7d6d9-8b83-4cc4-851e-59e7d4a7d80c'
);


-- 2. DIML xref -> package_id (COLE keys off package_id)
SELECT
    x.recordID,
    x.package_id
FROM LINKTOPETL.CS_Digital.dbo.tblDimlXref x
WHERE x.recordID IN (
    '97820b78-78c3-11eb-87ba-00505681224b',
    'a993c242-c03d-11eb-abaa-00505681224b',
    '6109278c-221e-4a4c-b116-26dc42aded3c',
    'bf4f0a7e-80cb-11ec-babc-00505681224b',
    'cdfc6cc8-96cb-11ec-a054-00505681224b',
    '17a9fb26-acc4-11ec-8364-00505681224b',
    '68479647-ee74-402f-ba35-48c97a8f027c',
    '6f292243-fa73-4548-8062-41dad64324d0',
    'bd096468-d346-4c93-97a1-e5c64296125a',
    'b6d7d6d9-8b83-4cc4-851e-59e7d4a7d80c'
);


-- 3. COLE processing log — status for each record
--    no rows             -> never processed
--    error col NOT NULL  -> COLE failed; reprocess candidate
--    both errors NULL    -> COLE ran clean; real content gap
SELECT
    x.recordID,
    l.package_id,
    l.inputDataset,
    l.OCRErrorMessage,
    l.IIEErrorMessage,
    l._OCRModifiedDateTime,
    l._IIEModifiedDateTime,
    l.OCRs3Path
FROM LINKTOPETL.CS_Digital.dbo.tblDimlXref x
JOIN LINKTOPETL.CS_Digital.cole.tblRecordProcessingLogs l
    ON l.package_id = x.package_id
WHERE x.recordID IN (
    '97820b78-78c3-11eb-87ba-00505681224b',
    'a993c242-c03d-11eb-abaa-00505681224b',
    '6109278c-221e-4a4c-b116-26dc42aded3c',
    'bf4f0a7e-80cb-11ec-babc-00505681224b',
    'cdfc6cc8-96cb-11ec-a054-00505681224b',
    '17a9fb26-acc4-11ec-8364-00505681224b',
    '68479647-ee74-402f-ba35-48c97a8f027c',
    '6f292243-fa73-4548-8062-41dad64324d0',
    'bd096468-d346-4c93-97a1-e5c64296125a',
    'b6d7d6d9-8b83-4cc4-851e-59e7d4a7d80c'
);


-- 4. Staleness check — image modified after COLE last ran?
--    image_newer_than_cole = 1 -> possible reprocess candidate; confirm via S3 head-object
--    image_newer_than_cole = 0 -> COLE saw the current image; content gap confirmed
SELECT
    s.recordID,
    s.s3FilePath,
    s.pageCount,
    s.fileSize,
    s._ModifiedDateTime                                             AS image_ModifiedDateTime,
    s._ModifiedBy                                                   AS image_ModifiedBy,
    l._OCRModifiedDateTime,
    l._IIEModifiedDateTime,
    CASE
        WHEN s._ModifiedDateTime >
             COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime)
        THEN 1 ELSE 0
    END                                                             AS image_newer_than_cole,
    DATEDIFF(day,
             COALESCE(l._IIEModifiedDateTime, l._OCRModifiedDateTime),
             s._ModifiedDateTime)                                   AS days_image_newer_than_cole
FROM dbo.tblS3Image s
JOIN LINKTOPETL.CS_Digital.dbo.tblDimlXref x
    ON x.recordID = s.recordID
JOIN LINKTOPETL.CS_Digital.cole.tblRecordProcessingLogs l
    ON l.package_id = x.package_id
WHERE s.recordID IN (
    '97820b78-78c3-11eb-87ba-00505681224b',
    'a993c242-c03d-11eb-abaa-00505681224b',
    '6109278c-221e-4a4c-b116-26dc42aded3c',
    'bf4f0a7e-80cb-11ec-babc-00505681224b',
    'cdfc6cc8-96cb-11ec-a054-00505681224b',
    '17a9fb26-acc4-11ec-8364-00505681224b',
    '68479647-ee74-402f-ba35-48c97a8f027c',
    '6f292243-fa73-4548-8062-41dad64324d0',
    'bd096468-d346-4c93-97a1-e5c64296125a',
    'b6d7d6d9-8b83-4cc4-851e-59e7d4a7d80c'
);