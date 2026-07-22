-- Records uploaded by LND-8093 with COLE processing errors
SELECT
    s.recordID,
    s.s3FilePath,
    l.package_id,
    l.inputDataset,
    l.OCRErrorMessage,
    l.IIEErrorMessage,
    l._OCRModifiedDateTime,
    l._IIEModifiedDateTime,
    l.OCRs3Path
FROM [AUS2-DTF-PAP01V].countyScansTitle.dbo.tblS3Image s
JOIN CS_Digital.dbo.tblDimlXref x ON x.recordID = s.recordID  -- verify column name
JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = x.package_id
WHERE s._ModifiedBy = 'LND-8093'
  AND (l.OCRErrorMessage IS NOT NULL OR l.IIEErrorMessage IS NOT NULL)
ORDER BY l._OCRModifiedDateTime DESC;


-- Records uploaded by LND-8093 with no entry in tblRecordProcessingLogs
SELECT
    s.recordID,
    s.s3FilePath,
    x.package_id
FROM [AUS2-DTF-PAP01V].countyScansTitle.dbo.tblS3Image s
LEFT JOIN CS_Digital.dbo.tblDimlXref x ON x.recordID = s.recordID  -- verify column name
LEFT JOIN CS_Digital.cole.tblRecordProcessingLogs l ON l.package_id = x.package_id
WHERE s._ModifiedBy = 'LND-8093'
  AND l.package_id IS NULL
ORDER BY s.recordID;