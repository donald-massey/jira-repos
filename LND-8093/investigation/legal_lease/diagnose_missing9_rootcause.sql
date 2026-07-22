-- Root cause for the 9 group-3 leases present in Div1 selection but absent from legal_lease.
--
-- Mechanism: the producer emits one protobuf per lease (build_messages merges land
-- descriptions how="left", so a zero-tract lease is STILL published). The legal_lease index
-- is one doc per tract, keyed by mapping_id = Div1 tblleaseAbstractMapping.mappingid
-- (div1_get_land_descriptions.sql: m.mappingid AS legacy_mapping_id). A lease with no
-- abstract mappings therefore yields zero per-tract docs -> absent from the index, even
-- though the producer published it. This is the downstream per-tract explosion, not a
-- producer drop and not the S3 backfill.
--
-- Q1 confirms it: the 9 MISSING should show 0 mappings; the 17 PRESENT should show >=1.
-- Run against Div1 (linked-server prefix shown; strip it if running directly on Div1_Daily).

WITH lease (lease_id, expected) AS (
    SELECT * FROM (VALUES
        (4989831,'MISSING'),(4547892,'MISSING'),(4547893,'MISSING'),(4547894,'MISSING'),
        (4547895,'MISSING'),(4547896,'MISSING'),(4547897,'MISSING'),(4547898,'MISSING'),
        (4233079,'MISSING'),
        (4612282,'present'),(4621210,'present'),(4892483,'present'),(4892458,'present'),
        (4892559,'present'),(4893932,'present'),(4245391,'present'),(4233745,'present'),
        (4240362,'present'),(4238794,'present'),(4238366,'present'),(4232753,'present'),
        (4201285,'present'),(4235962,'present'),(4233997,'present'),(4233081,'present'),
        (4233080,'present')
    ) v (lease_id, expected)
)
SELECT
    l.expected,
    l.lease_id,
    COUNT(m.mappingid)                                                  AS total_mappings,
    SUM(CASE WHEN a.StateID NOT IN (91,102,93) THEN 1 ELSE 0 END)       AS mappings_after_state_filter
FROM lease l
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblleaseAbstractMapping] m ON m.LeaseID = l.lease_id
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblAbstract]             a ON a.AbstractID = m.abstractID
GROUP BY l.expected, l.lease_id
ORDER BY l.expected, l.lease_id;

-- Q2 (secondary) — CSTitle tbllandDescription coverage for the same leases' recordIDs.
-- Producer also nests CSTitle land descriptions, but those don't carry a Div1 mapping_id,
-- so they don't generate per-tract docs. If the 9 MISSING have CSTitle LDs yet are still
-- absent, that confirms the doc key is the Div1 mapping_id, not the CSTitle land description.
-- Run against countyScansTitle.
SELECT
    ld.recordID,
    COUNT(*)                                              AS total_land_desc,
    SUM(CASE WHEN ld.IsDeleted = 0 THEN 1 ELSE 0 END)     AS active_land_desc
FROM countyScansTitle.dbo.tbllandDescription ld
WHERE ld.recordID IN (
    -- 9 MISSING
    'f98d1a0d-f424-4c8c-8e78-8940fc64ef3a', '7d321a52-931a-4040-9ace-f084d06babf4',
    '3bfc2172-d7df-43d8-8b45-efb24d689a6c', '1218f1e7-4a3e-4b5b-aa88-7dbebdb2dab2',
    '80db494e-e73b-4c6c-81ba-741a9d890685', '1b8d765f-0d20-4a58-9ada-48b8f80fd1df',
    '064e5d99-8bfe-4157-a1c5-3724c2370b85', '9dcd0169-ce07-410b-aa25-0d46e22f7cd8',
    '66d99bf5-949e-4f25-9655-cb41beb55092'
)
GROUP BY ld.recordID
ORDER BY ld.recordID;


SELECT COUNT(*) FROM dbo.tblrecord r
INNER JOIN cole.tblRecordNotProcessedChunk p ON p.countyID = r.countyID AND p.recordID = r.recordID
LEFT JOIN dbo.tblS3Image s ON r.recordID = s.recordID
WHERE s.recordID IS NULL OR s.s3FilePath IS NULL