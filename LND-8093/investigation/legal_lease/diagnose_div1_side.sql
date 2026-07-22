-- Div1-side diagnosis for the 128 LND-8093 lease records that pass every CSTitle gate
-- but still didn't publish to legal_lease. The producer's entry point is Div1
-- tblLegalLease (div1_get_modified_instrument_ids.sql): a lease only enters the run if
--   dt.category = 2  AND  dt.shortText NOT IN ('Assignment','Mineral Deed')
--   AND (L.updated >= last_run OR svg.updated >= last_run OR grantee alias modified)
-- LND-8093 wrote only tblS3Image, so it bumped NONE of those timestamps.
--
-- Run from the CSTitle connection; Div1 reached via the [LinktoDiv1Repl] linked server
-- (same path the producer uses in cstitle_get_modified_instrument_ids.sql:8).

WITH lnd AS (
    SELECT r.recordID, r.instrumentTypeID, c.countyName, ls.stateAbbreviation
    FROM countyScansTitle.dbo.tblS3Image s
    JOIN countyScansTitle.dbo.tblrecord         r  ON r.recordID = s.recordID
    JOIN countyScansTitle.dbo.tbllookupCounties c  ON c.countyID = r.countyID
    JOIN countyScansTitle.dbo.tbllookupStates   ls ON ls.StateID = c.StateID
    WHERE s._ModifiedBy = 'LND-8093'
      AND r.statusID IN (4,10)
      AND r.recordIsLease = 1
      AND c.countyName NOT LIKE 'TRAINING_%'
),
linked AS (
    SELECT l.recordID, l.instrumentTypeID, l.countyName, l.stateAbbreviation, el.leaseId
    FROM lnd l
    OUTER APPLY (
        SELECT TOP 1 leaseId FROM countyScansTitle.dbo.tblexportLog
        WHERE recordID = l.recordID AND leaseId IS NOT NULL
        ORDER BY _ModifiedDateTime DESC
    ) el
    WHERE el.leaseId IS NOT NULL
)
SELECT
    k.recordID, k.stateAbbreviation, k.countyName, k.instrumentTypeID AS cstitle_instrument,
    k.leaseId,
    tl.instrument       AS div1_instrument,
    dt.category         AS div1_category,
    dt.shortText        AS div1_short_text,
    tl.updated          AS div1_lease_updated,
    svg.updated         AS div1_svg_updated,
    CASE
        WHEN tl.leaseId IS NULL              THEN 'leaseId not in Div1 tblLegalLease (orphaned mapping)'
        WHEN dt.category IS NULL             THEN 'instrument has no tblDisplayText match'
        WHEN dt.category <> 2                THEN 'Div1 category <> 2 (not treated as a lease)'
        WHEN dt.shortText IN ('Assignment','Mineral Deed')
                                             THEN 'Div1 shortText excluded'
        ELSE 'eligible in Div1 -> not modified in run window (LND-8093 bumped no timestamp)'
    END AS div1_reason
FROM linked k
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblLegalLease] tl
       ON tl.leaseId = k.leaseId
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblDisplayText] dt
       ON dt.textCode = tl.instrument
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblSVGPolygonGroupDetail] svg
       ON svg.groupId = tl.svgPolygonGroupDetailId
ORDER BY div1_reason, k.stateAbbreviation, k.countyName;

-- Rollup: how many records fall into each Div1 reason
WITH lnd AS (
    SELECT r.recordID
    FROM countyScansTitle.dbo.tblS3Image s
    JOIN countyScansTitle.dbo.tblrecord         r  ON r.recordID = s.recordID
    JOIN countyScansTitle.dbo.tbllookupCounties c  ON c.countyID = r.countyID
    WHERE s._ModifiedBy = 'LND-8093'
      AND r.statusID IN (4,10)
      AND r.recordIsLease = 1
      AND c.countyName NOT LIKE 'TRAINING_%'
),
linked AS (
    SELECT l.recordID, el.leaseId
    FROM lnd l
    OUTER APPLY (
        SELECT TOP 1 leaseId FROM countyScansTitle.dbo.tblexportLog
        WHERE recordID = l.recordID AND leaseId IS NOT NULL
        ORDER BY _ModifiedDateTime DESC
    ) el
    WHERE el.leaseId IS NOT NULL
)
SELECT div1_reason, COUNT(*) AS records
FROM (
    SELECT
        CASE
            WHEN tl.leaseId IS NULL              THEN 'leaseId not in Div1 tblLegalLease (orphaned mapping)'
            WHEN dt.category IS NULL             THEN 'instrument has no tblDisplayText match'
            WHEN dt.category <> 2                THEN 'Div1 category <> 2 (not treated as a lease)'
            WHEN dt.shortText IN ('Assignment','Mineral Deed')
                                                 THEN 'Div1 shortText excluded'
            ELSE 'eligible in Div1 -> not modified in run window (LND-8093 bumped no timestamp)'
        END AS div1_reason
    FROM linked k
    LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblLegalLease] tl ON tl.leaseId = k.leaseId
    LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblDisplayText] dt ON dt.textCode = tl.instrument
) x
GROUP BY div1_reason
ORDER BY records DESC;