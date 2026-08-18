-- Verify DB state for a cross-section of repaired records
-- Checks tblS3Image metadata and tblrecord.fileExtension alignment
-- Run against countyScansTitle on AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM

DECLARE @sample TABLE (recordID VARCHAR(36));
INSERT INTO @sample VALUES
-- pdf_valid kind (from rerun3)
('00051be0-bfa1-4534-8b30-b213c0f5dac1'),
('00051e27-d68a-4412-a310-ea27710bfb44'),
('00052349-f742-4ef7-aee9-ad9699948de6'),
-- tif_converted kind (from rerun3)
('8bb0d496-17a6-4a10-bf67-5ab8eb2ef945'),
('8d26cbff-3fce-40e1-9db8-2a46a2ec7acf'),
('70e250b3-172e-4ec3-b768-e146a33d8738'),
-- tif_converted kind (from main run)
('00dc069f-708f-440e-a298-dcb0226b6db2'),
('015ca42c-35d0-4533-9e31-ae2c5c319dee'),
('19e360e4-cfff-4d69-ae8b-065cd76112ed'),
('1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e'),
('1a3ac7dc-ceb6-4394-84a4-be6da71440b9');

SELECT
    r.recordID,
    r.fileExtension          AS rec_fileExtension,
    r.statusID,
    s.s3FilePath,
    s.pageCount,
    s.fileSizeBytes,
    s._ModifiedBy,
    s._ModifiedDate
FROM [countyScansTitle].[dbo].[tblrecord] r
LEFT JOIN [countyScansTitle].[dbo].[tblS3Image] s
    ON s.recordID = r.recordID
WHERE r.recordID IN (SELECT recordID FROM @sample)
ORDER BY r.recordID;
