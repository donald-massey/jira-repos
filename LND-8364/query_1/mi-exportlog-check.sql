-- Level 1: tblexportLog status for the three MI records.
-- A NULL leaseID means IIF Lease Importer never created a DIV1 entry —
-- the proposed fix (no mapping_id → ES only) does NOT cover these.
-- Run against countyScansTitle.
SELECT
    lower(R.recordID)             AS record_id,
    R.recordNumber,
    R.statusID,
    R.recordIsLease,
    R.fileDate,
    R._ModifiedDateTime           AS record_modified,
    el.leaseID,
    el.zipName,
    el._ModifiedDateTime          AS export_log_modified
FROM dbo.tblRecord R
LEFT JOIN dbo.tblexportLog el ON el.recordID = R.recordID
WHERE lower(R.recordID) IN (
    'cd130801-8bad-48c3-bce2-81336b1f2e14',  -- ALCONA
    '2f27f271-3a42-4329-813c-ba15bdc4b1b5',  -- ALPENA
    '9504fdef-c20b-42f8-9cce-09a3991e9223'   -- MISSAUKEE
);
