-- Scope check: of DIV1 mapped leases (those that publish a legal_lease ES doc),
-- how many have NO SVG polygon (svgPolygonGroupDetailId IS NULL)?
--
-- Sample of 10 came back 10/10 null-svg. This measures whether that generalizes to the
-- full ES missing-geometry population (219,765 docs as of legal_lease_20260811).
--
-- A mapped lease with null svgPolygonGroupDetailId = geometry never producible = the
-- "MAPPED — NO POLYGON IN DIV1" bucket. If this count ~= 219,765, that's the dominant cause.
--
-- Run on CSTitle server (aus2-dtf-pap01v.na.drillinginfo.com) — reaches DIV1 via LinktoDiv1Repl.

-- Stage distinct mapped LeaseIDs from DIV1
SELECT DISTINCT LeaseID
INTO #mapped
FROM OPENQUERY([LinktoDiv1Repl],
    'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping');

-- Stage LeaseID + svg pointer from DIV1
SELECT LeaseID, svgPolygonGroupDetailId
INTO #legallease
FROM OPENQUERY([LinktoDiv1Repl],
    'SELECT LeaseID, svgPolygonGroupDetailId FROM div1_Daily.dbo.tblLegalLease');

-- Decompose mapped-lease population by SVG presence
SELECT
    CASE WHEN ll.svgPolygonGroupDetailId IS NULL THEN 'NO SVG (no geometry producible)'
         ELSE 'HAS SVG (geometry expected)' END AS svg_status,
    COUNT(*) AS lease_count
FROM #mapped m
JOIN #legallease ll ON ll.LeaseID = m.LeaseID
GROUP BY CASE WHEN ll.svgPolygonGroupDetailId IS NULL THEN 'NO SVG (no geometry producible)'
              ELSE 'HAS SVG (geometry expected)' END
ORDER BY lease_count DESC;

DROP TABLE #mapped;
DROP TABLE #legallease;
