-- Diagnose which join is blocking the 0-row result

-- 1. Base records exist?
SELECT recordID, fileExtension, statusID
FROM [countyScansTitle].[dbo].[tblrecord]
WHERE recordID IN (
    '00dc069f-708f-440e-a298-dcb0226b6db2',
    '015ca42c-35d0-4533-9e31-ae2c5c319dee',
    '19e360e4-cfff-4d69-ae8b-065cd76112ed',
    '1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e',
    '1a3ac7dc-ceb6-4394-84a4-be6da71440b9'
);

-- 2. tblLandDescription has rows for these?
SELECT recordID, LandDescriptionId
FROM [countyScansTitle].[dbo].[tblLandDescription]
WHERE recordID IN (
    '00dc069f-708f-440e-a298-dcb0226b6db2',
    '015ca42c-35d0-4533-9e31-ae2c5c319dee',
    '19e360e4-cfff-4d69-ae8b-065cd76112ed',
    '1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e',
    '1a3ac7dc-ceb6-4394-84a4-be6da71440b9'
);

-- 3. tblexportLog has rows for these?
SELECT recordID, LeaseId
FROM [countyScansTitle].[dbo].[tblexportLog]
WHERE recordID IN (
    '00dc069f-708f-440e-a298-dcb0226b6db2',
    '015ca42c-35d0-4533-9e31-ae2c5c319dee',
    '19e360e4-cfff-4d69-ae8b-065cd76112ed',
    '1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e',
    '1a3ac7dc-ceb6-4494-84a4-be6da71440b9'
);
