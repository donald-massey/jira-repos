-- Group 3: LND-8093 lease records that are genuine category-2 Div1 leases, passed all
-- CSTitle gates, yet didn't publish in the full reload. Check county coverage + the
-- per-county watermark the producer actually keys on (tblDataLoadersPerCounty
-- .LastProcessedDateLandLeaseProducer, per cstitle_get_lease_counties.sql), and
-- MasterCountyLookup presence (per cstitle_get_counties.sql). Run from CSTitle.

WITH lnd AS (
    SELECT r.recordID, r.countyID, c.countyName, c.Div1CountyID, ls.stateAbbreviation
    FROM countyScansTitle.dbo.tblS3Image s
    JOIN countyScansTitle.dbo.tblrecord         r  ON r.recordID = s.recordID
    JOIN countyScansTitle.dbo.tbllookupCounties c  ON c.countyID = r.countyID
    JOIN countyScansTitle.dbo.tbllookupStates   ls ON ls.StateID = c.StateID
    WHERE s._ModifiedBy = 'LND-8093'
      AND r.statusID IN (4,10)
      AND r.recordIsLease = 1
      AND c.countyName NOT LIKE 'TRAINING_%'
),
eligible AS (   -- keep only records whose leaseId is a category-2 Div1 lease (producer's rule)
    SELECT l.recordID, l.countyID, l.countyName, l.Div1CountyID, l.stateAbbreviation,
           el.leaseId, tl.updated AS div1_lease_updated
    FROM lnd l
    CROSS APPLY (
        SELECT TOP 1 leaseId FROM countyScansTitle.dbo.tblexportLog
        WHERE recordID = l.recordID AND leaseId IS NOT NULL
        ORDER BY _ModifiedDateTime DESC
    ) el
    JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblLegalLease] tl ON tl.leaseId = el.leaseId
    JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblDisplayText] dt
         ON dt.textCode = tl.instrument AND dt.category = 2
    WHERE dt.shortText NOT IN ('Assignment','Mineral Deed')
)
SELECT
    e.stateAbbreviation, e.countyName, e.Div1CountyID,
    COUNT(*)                         AS eligible_records,
    MIN(e.div1_lease_updated)        AS oldest_lease_updated,
    MAX(e.div1_lease_updated)        AS newest_lease_updated,
    CASE WHEN dl.countyID IS NULL THEN 'MISSING from tblDataLoadersPerCounty (never iterated)'
         ELSE 'present' END          AS in_dataloaders,
    dl.LastProcessedDateLandLeaseProducer AS county_watermark,
    CASE WHEN mcl.LeasingID IS NULL THEN 'MISSING from MasterCountyLookup'
         ELSE 'present' END          AS in_mastercountylookup
FROM eligible e
LEFT JOIN countyScansTitle.dbo.tblDataLoadersPerCounty dl ON dl.countyID = e.countyID
LEFT JOIN countyScansTitle.Tracker.MasterCountyLookup mcl ON mcl.LeasingID = e.Div1CountyID
GROUP BY e.stateAbbreviation, e.countyName, e.Div1CountyID,
         dl.countyID, dl.LastProcessedDateLandLeaseProducer, mcl.LeasingID
ORDER BY eligible_records DESC;