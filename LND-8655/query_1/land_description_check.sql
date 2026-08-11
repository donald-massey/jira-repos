/* ============================================================================
   LND-8655 — Starter: land descriptions + image paths for affected records
   Server: AUS2-PHX-DSQL01  DB: countyScansTitle

   37 rows in the xlsx (24 unique recordIDs — Plaquemines entries are duplicated).
   All records have statusID=4 and non-null Div1_LeaseID, so IIF/Level 1 is clean.
   Checking whether CSTitle tblLandDescription rows exist.
   Zero rows per recordID = no legal to enrich = mapping_id NULL = Glue drops.
   ============================================================================ */

/* ---- A) Land descriptions for all 24 unique recordIDs ---- */
SELECT
    LOWER(L.recordId)       AS record_id,
    L.landDescriptionID,
    L.section,
    L.township,
    L.rangeOrBlock,
    L.survey,
    L.AbstractName,
    L.BriefLegal,
    L.IsDeleted
FROM [countyScansTitle].[dbo].[tblLandDescription] L
WHERE L.recordID IN (
    -- Beauregard (9)
    '008773a0-be1c-4057-b441-d2a889964271',
    '91d21121-e0c4-441e-832c-5850202a2edb',
    '9676f3d8-cc35-4d71-9512-e6cbb294c985',
    '9c938807-1980-4898-9fdd-76689932382d',
    'a5a84d16-01d0-49bb-b681-7090f40aa535',
    'd740bc6f-cb58-4dea-a563-63309682214b',
    'e69aab8f-0fb7-40fe-a21c-75b90399d65f',
    '7f84be77-3052-485b-a438-f2e17b5aa100',
    'ac257b8b-611e-4333-8863-ca66f06e8d59',
    -- Plaquemines (14 unique — xlsx has each row twice)
    '3bee5a55-d429-45a4-9df6-aa15bce31f32',
    '915c8314-6141-4ca0-a6bf-c80ecbdb9160',
    '8627418e-47b3-4d27-8c4f-bb84c6153461',
    '4ca6bd12-af24-437b-81ed-b883a966a4ef',
    '1831f486-a793-480d-8711-80f7ad74bb03',
    '23072731-e86b-4654-b0fe-496f5d8b0777',
    '071ff440-1ff4-49be-86ab-94c86a2e94ed',
    '0f38fa5b-b57f-4d62-af96-61a2ec1471c9',
    '7d056e18-fcf4-4b48-90b6-ccafeebdac59',
    '5b0b2846-3d93-4e0a-b46c-57799dda3dbb',
    '67aede5a-88ba-4ae1-94b5-37f122a39502',
    'c3db673d-a60a-4713-8384-b633352ef334',
    'ccfa9f65-2f8b-46d6-85a3-1590f63aee6f',
    'd1cc62c9-a5bf-4da6-a2b3-2cd0036fe14f',
    -- St. Bernard (1)
    'ada76388-69c6-11e8-9233-00505681224b'
);


/* ---- B) Full image paths from tblS3Image for the same records ---- */
SELECT DISTINCT
    LOWER(r.recordID)           AS record_id,
    cl.countyName,
    r.storageFilePath,
    s.s3FilePath,
    s.fileSizeBytes,
    s.pageCount
FROM [countyScansTitle].[dbo].[tblRecord] r
JOIN [countyScansTitle].[dbo].[tblLookupCounties] cl ON cl.countyID = r.countyID
JOIN [countyScansTitle].[dbo].[tblS3Image] s ON s.recordID = r.recordID
WHERE r.recordID IN (
    '008773a0-be1c-4057-b441-d2a889964271',
    '91d21121-e0c4-441e-832c-5850202a2edb',
    '9676f3d8-cc35-4d71-9512-e6cbb294c985',
    '9c938807-1980-4898-9fdd-76689932382d',
    'a5a84d16-01d0-49bb-b681-7090f40aa535',
    'd740bc6f-cb58-4dea-a563-63309682214b',
    'e69aab8f-0fb7-40fe-a21c-75b90399d65f',
    '7f84be77-3052-485b-a438-f2e17b5aa100',
    'ac257b8b-611e-4333-8863-ca66f06e8d59',
    '3bee5a55-d429-45a4-9df6-aa15bce31f32',
    '915c8314-6141-4ca0-a6bf-c80ecbdb9160',
    '8627418e-47b3-4d27-8c4f-bb84c6153461',
    '4ca6bd12-af24-437b-81ed-b883a966a4ef',
    '1831f486-a793-480d-8711-80f7ad74bb03',
    '23072731-e86b-4654-b0fe-496f5d8b0777',
    '071ff440-1ff4-49be-86ab-94c86a2e94ed',
    '0f38fa5b-b57f-4d62-af96-61a2ec1471c9',
    '7d056e18-fcf4-4b48-90b6-ccafeebdac59',
    '5b0b2846-3d93-4e0a-b46c-57799dda3dbb',
    '67aede5a-88ba-4ae1-94b5-37f122a39502',
    'c3db673d-a60a-4713-8384-b633352ef334',
    'ccfa9f65-2f8b-46d6-85a3-1590f63aee6f',
    'd1cc62c9-a5bf-4da6-a2b3-2cd0036fe14f',
    'ada76388-69c6-11e8-9233-00505681224b'
)
ORDER BY r.countyName, record_id;


/* ---- C) Instrument type full + recordIsLease for all 24 records ---- */
SELECT
    LOWER(r.recordID)   AS record_id,
    cl.countyName,
    r.recordIsLease,
    f.InstrumentTypeFull
FROM [countyScansTitle].[dbo].[tblRecord] r
JOIN [countyScansTitle].[dbo].[tblLookupCounties] cl ON cl.countyID = r.countyID
JOIN [countyScansTitle].[dbo].[tblLookupInstrumentTypeFull] f ON f.InstrumentTypeFullId = r.InstrumentTypeFullId
WHERE r.recordID IN (
    -- Beauregard (9)
    '008773a0-be1c-4057-b441-d2a889964271',
    '7f84be77-3052-485b-a438-f2e17b5aa100',
    '91d21121-e0c4-441e-832c-5850202a2edb',
    '9676f3d8-cc35-4d71-9512-e6cbb294c985',
    '9c938807-1980-4898-9fdd-76689932382d',
    'a5a84d16-01d0-49bb-b681-7090f40aa535',
    'ac257b8b-611e-4333-8863-ca66f06e8d59',
    'd740bc6f-cb58-4dea-a563-63309682214b',
    'e69aab8f-0fb7-40fe-a21c-75b90399d65f',
    -- Plaquemines (14)
    '071ff440-1ff4-49be-86ab-94c86a2e94ed',
    '0f38fa5b-b57f-4d62-af96-61a2ec1471c9',
    '1831f486-a793-480d-8711-80f7ad74bb03',
    '23072731-e86b-4654-b0fe-496f5d8b0777',
    '3bee5a55-d429-45a4-9df6-aa15bce31f32',
    '4ca6bd12-af24-437b-81ed-b883a966a4ef',
    '5b0b2846-3d93-4e0a-b46c-57799dda3dbb',
    '67aede5a-88ba-4ae1-94b5-37f122a39502',
    '7d056e18-fcf4-4b48-90b6-ccafeebdac59',
    '8627418e-47b3-4d27-8c4f-bb84c6153461',
    '915c8314-6141-4ca0-a6bf-c80ecbdb9160',
    'c3db673d-a60a-4713-8384-b633352ef334',
    'ccfa9f65-2f8b-46d6-85a3-1590f63aee6f',
    'd1cc62c9-a5bf-4da6-a2b3-2cd0036fe14f',
    -- St. Bernard (1)
    'ada76388-69c6-11e8-9233-00505681224b'
)
ORDER BY cl.countyName, r.recordID;