-- LND-7899: McKean, PA — Level 2 mapping check
-- Run on countyScansTitle. DIV1 queries use the [LinktoDiv1Repl] linked server.
--
-- Interpretation:
--   Both DIV1 queries empty + no tblLandDescription rows -> no mapping_id, glue drops them (same as LND-8426).
--   DIV1 mapping exists -> producer is the suspect, test via dev Kafka topic.

USE countyScansTitle;


-- 1. DIV1 abstract mapping for the 10 McKean leaseIDs
SELECT *
FROM OPENQUERY([LinktoDiv1Repl], '
    SELECT
        lam.mappingid,
        lam.leaseID,
        lam.abstractID,
        lam.parcelNum
    FROM div1_daily.dbo.tblleaseAbstractMapping lam
    WHERE lam.leaseID IN (
        4734654, 4752229, 4786016, 4805108, 4813204,
        4826786, 4926176, 5084766, 5098662, 5186304
    )
');


-- 2. CSTitle land descriptions
SELECT
    ld.recordID,
    COUNT(*) AS ld_count
FROM dbo.tblLandDescription ld
WHERE ld.recordID IN (
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
)
GROUP BY ld.recordID;


-- 3. PA additional fields parcel-number path (PA/OH/WV get mapping_id this way, not via base land description)
SELECT
    af.recordID,
    af.Pennsylvania_parcelNumber,
    div1.mappingid,
    div1.leaseID
FROM dbo.TblAddsFields af
LEFT JOIN OPENQUERY([LinktoDiv1Repl], '
    SELECT mappingid, leaseID, parcelNum
    FROM div1_daily.dbo.tblleaseAbstractMapping
') div1 ON div1.parcelNum = af.Pennsylvania_parcelNumber
WHERE af.recordID IN (
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
