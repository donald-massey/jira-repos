-- Level 2: DIV1 abstract mapping check for the MI leaseIDs.
-- Run this only if mi-exportlog-check.sql returns non-null leaseIDs.
-- Records with 0 mapping rows are the ones the proposed fix targets.
-- Replace the leaseID values with actual results from mi-exportlog-check.sql.
-- Run against countyScansTitle (uses the LinktoDiv1Repl linked server).

-- Step 1: stage the mapping IDs for the specific leaseIDs.
CREATE TABLE #mi_mapping (LeaseID BIGINT, mapping_count INT);

INSERT INTO #mi_mapping (LeaseID, mapping_count)
SELECT
    LeaseID,
    COUNT(*) AS mapping_count
FROM OPENQUERY(
    [LinktoDiv1Repl],
    'SELECT LeaseID
     FROM div1_Daily.dbo.tblleaseAbstractMapping
     WHERE LeaseID IN (<leaseID_alcona>, <leaseID_alpena>, <leaseID_missaukee>)'
)
GROUP BY LeaseID;

-- Step 2: report mapping status per lease.
-- leaseIDs with no row here have no abstract mapping — fix applies to these.
SELECT
    el.leaseID,
    lower(R.recordID)    AS record_id,
    R.recordNumber,
    ISNULL(m.mapping_count, 0) AS mapping_count,
    CASE WHEN m.LeaseID IS NULL THEN 'NO MAPPING — fix applies'
         ELSE 'HAS MAPPING — investigate further' END AS status
FROM dbo.tblRecord R
JOIN dbo.tblexportLog el ON el.recordID = R.recordID
LEFT JOIN #mi_mapping m ON m.LeaseID = el.leaseID
WHERE lower(R.recordID) IN (
    'cd130801-8bad-48c3-bce2-81336b1f2e14',
    '2f27f271-3a42-4329-813c-ba15bdc4b1b5',
    '9504fdef-c20b-42f8-9cce-09a3991e9223'
)
AND el.leaseID IS NOT NULL;

DROP TABLE #mi_mapping;
