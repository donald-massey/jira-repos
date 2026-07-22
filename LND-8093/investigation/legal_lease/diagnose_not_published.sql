-- Why LND-8093 lease records didn't publish to the legal_lease ES index.
-- land-lease-producer selects records ONLY via tblexportLog.leaseId (link to a
-- Div1 legal lease). The S3 image backfill fills image_location via a LEFT JOIN;
-- it never drives selection. This query replays the producer's gates against the
-- LND-8093 lease records and flags the failing gate for each.
--
-- Gates replayed (from cstitle_get_modified_instrument_ids.sql + cstitle_get_instruments.sql):
--   1. exportLog link:   INNER JOIN tblexportLog with leaseId IS NOT NULL
--   2. status:           StatusID IN (4,10,16)
--   3. instrument type:  instrumentTypeID NOT IN ('ASN','MD')
--   4. fileDate:         fileDate IS NOT NULL
--   5. county mapping:   Tracker.MasterCountyLookup INNER JOIN on Div1CountyID
-- (Div1-side gate — leaseId must be a category=2 lease, not Assignment/Mineral Deed —
--  is cross-database and not evaluated here.)

WITH lnd AS (
    SELECT r.recordID, r.statusID, r.instrumentTypeID, r.fileDate,
           r.recordIsLease, c.countyName, c.Div1CountyID, ls.stateAbbreviation
    FROM countyScansTitle.dbo.tblS3Image s
    JOIN countyScansTitle.dbo.tblrecord         r  ON r.recordID = s.recordID
    JOIN countyScansTitle.dbo.tbllookupCounties c  ON c.countyID = r.countyID
    JOIN countyScansTitle.dbo.tbllookupStates   ls ON ls.StateID = c.StateID
    WHERE s._ModifiedBy = 'LND-8093'
      AND r.statusID IN (4,10)
      AND r.recordIsLease = 1
      AND c.countyName NOT LIKE 'TRAINING_%'
)
SELECT
    l.recordID, l.countyName, l.stateAbbreviation, l.instrumentTypeID, l.statusID, l.fileDate,
    CASE
        WHEN el.leaseId IS NULL THEN 'no exportLog leaseId (not linked to a Div1 lease)'
        WHEN l.statusID NOT IN (4,10,16) THEN 'status excluded'
        WHEN l.instrumentTypeID IN ('ASN','MD') THEN 'instrument type ASN/MD excluded'
        WHEN l.fileDate IS NULL THEN 'fileDate null'
        WHEN mcl.leasingID IS NULL THEN 'county has no Div1CountyID -> MasterCountyLookup miss'
        ELSE 'passes CSTitle gates -> check Div1 lease category / producer run window'
    END AS exclusion_reason
FROM lnd l
OUTER APPLY (
    SELECT TOP 1 leaseId
    FROM countyScansTitle.dbo.tblexportLog
    WHERE recordID = l.recordID AND leaseId IS NOT NULL
    ORDER BY _ModifiedDateTime DESC
) el
LEFT JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.leasingID = l.Div1CountyID
ORDER BY exclusion_reason, l.stateAbbreviation, l.countyName;

-- Summary rollup
WITH lnd AS (
    SELECT r.recordID, r.statusID, r.instrumentTypeID, r.fileDate, c.Div1CountyID
    FROM countyScansTitle.dbo.tblS3Image s
    JOIN countyScansTitle.dbo.tblrecord         r  ON r.recordID = s.recordID
    JOIN countyScansTitle.dbo.tbllookupCounties c  ON c.countyID = r.countyID
    JOIN countyScansTitle.dbo.tbllookupStates   ls ON ls.StateID = c.StateID
    WHERE s._ModifiedBy = 'LND-8093'
      AND r.statusID IN (4,10)
      AND r.recordIsLease = 1
      AND c.countyName NOT LIKE 'TRAINING_%'
)
SELECT exclusion_reason, COUNT(*) AS records
FROM (
    SELECT
        CASE
            WHEN el.leaseId IS NULL THEN 'no exportLog leaseId (not linked to a Div1 lease)'
            WHEN l.statusID NOT IN (4,10,16) THEN 'status excluded'
            WHEN l.instrumentTypeID IN ('ASN','MD') THEN 'instrument type ASN/MD excluded'
            WHEN l.fileDate IS NULL THEN 'fileDate null'
            WHEN mcl.leasingID IS NULL THEN 'county has no Div1CountyID -> MasterCountyLookup miss'
            ELSE 'passes CSTitle gates -> check Div1 lease category / producer run window'
        END AS exclusion_reason
    FROM lnd l
    OUTER APPLY (
        SELECT TOP 1 leaseId FROM countyScansTitle.dbo.tblexportLog
        WHERE recordID = l.recordID AND leaseId IS NOT NULL
        ORDER BY _ModifiedDateTime DESC
    ) el
    LEFT JOIN Tracker.dbo.MasterCountyLookup mcl ON mcl.leasingID = l.Div1CountyID
) x
GROUP BY exclusion_reason
ORDER BY records DESC;
