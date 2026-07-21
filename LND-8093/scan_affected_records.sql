-- LND-8093: Scan how many countyScansTitle records still need backfilling to S3.
-- "Affected" = a tblrecord row with a usable file path that has no tblS3Image entry yet.
-- Uses NOT EXISTS rather than NOT IN (NOT IN returns nothing if any recordID is NULL).

USE countyScansTitle;

-- 1) Headline count: every unprocessed record (no LND-6827 exclusions).
-- Returned 9,050,952 Records
SELECT COUNT(*) AS affected_records
FROM dbo.tblrecord tr
WHERE tr.storageFilePath != 'NONE'
  AND NOT EXISTS (
        SELECT 1 FROM dbo.tblS3Image s WHERE s.recordID = tr.recordID
      );


USE countyScansTitle;

-- 2) Conservative count: with the LND-6827 exclusions applied.
--    Run this alongside #1 so the gap between the two numbers is the
--    decision you need from Tyler (does the backfill include the excluded set?).
-- Returned 890 records
SELECT COUNT(*) AS affected_records_filtered
FROM dbo.tblrecord tr
WHERE tr.storageFilePath != 'NONE'
  AND tr.recordIsLease = 1
  AND tr.statusID IN (4, 16)
  AND tr.fileDate >= '2002-01-01'
  AND tr.countyID NOT IN (
        288,291,292,293,295,296,298,300,
        684,685,686,687,688,689,690,691,692,693,694,695,696,697,698,699,
        700,701,702,703,704,705,706,707,708,709,710,711,712,713,714,715,716,
        1187
      )
  AND NOT EXISTS (
        SELECT 1 FROM dbo.tblS3Image s WHERE s.recordID = tr.recordID
      );


USE countyScansTitle;
-- 3) Breakdown by state (headline scope) — gauges where the volume sits.
SELECT
    tls.stateAbbreviation,
    COUNT(*) AS affected_records
FROM dbo.tblrecord tr
JOIN dbo.tbllookupStates tls ON tls.stateID = tr.stateID
WHERE tr.storageFilePath != 'NONE'
  AND NOT EXISTS (
        SELECT 1 FROM dbo.tblS3Image s WHERE s.recordID = tr.recordID
      )
GROUP BY tls.stateAbbreviation
ORDER BY affected_records DESC;