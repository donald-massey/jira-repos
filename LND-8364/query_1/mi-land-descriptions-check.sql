-- Level 2b: CSTitle land description presence for the three MI records.
-- Records with zero rows in both tblLandDescription and TblAddsFields have
-- no parseable legal — same document-type limitation found in COLUMBIA, PA.
-- Run against countyScansTitle.

-- Base land descriptions.
SELECT
    lower(recordID) AS record_id,
    'tblLandDescription' AS source,
    COUNT(*) AS row_count
FROM dbo.tblLandDescription
WHERE lower(recordID) IN (
    'cd130801-8bad-48c3-bce2-81336b1f2e14',
    '2f27f271-3a42-4329-813c-ba15bdc4b1b5',
    '9504fdef-c20b-42f8-9cce-09a3991e9223'
)
GROUP BY recordID

UNION ALL

-- Additional fields (state-specific parcel / quarter descriptions).
SELECT
    lower(recordID) AS record_id,
    'TblAddsFields' AS source,
    COUNT(*) AS row_count
FROM dbo.TblAddsFields
WHERE lower(recordID) IN (
    'cd130801-8bad-48c3-bce2-81336b1f2e14',
    '2f27f271-3a42-4329-813c-ba15bdc4b1b5',
    '9504fdef-c20b-42f8-9cce-09a3991e9223'
)
GROUP BY recordID

ORDER BY record_id, source;
