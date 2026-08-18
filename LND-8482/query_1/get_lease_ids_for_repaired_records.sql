-- Get DIV1 lease IDs for the 08-14 repaired records
-- to verify they're published in legal_lease ES with a valid image_link

SELECT
    r.recordID,
    r.fileExtension,
    r.statusID,
    ld.LandDescriptionId,
    l.LeaseId
FROM [countyScansTitle].[dbo].[tblrecord] r
JOIN [countyScansTitle].[dbo].[tblexportLog] l ON l.recordID = r.recordID
JOIN [countyScansTitle].[dbo].[tblLandDescription] ld
    ON ld.recordID = r.recordID
WHERE r.recordID IN (
    '00dc069f-708f-440e-a298-dcb0226b6db2',
    '015ca42c-35d0-4533-9e31-ae2c5c319dee',
    '19e360e4-cfff-4d69-ae8b-065cd76112ed',
    '1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e',
    '1a3ac7dc-ceb6-4394-84a4-be6da71440b9'
)
ORDER BY r.recordID;
