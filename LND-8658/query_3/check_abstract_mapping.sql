/*
LND-8658 - Recent WV LegalLeases Not Published
Diagnostic query 3 (PRIMARY): abstract-mapping check.

Hypothesis (same root cause as LND-8426 "Recent PA LegalLeases Not Published"): these WV leases
reached Kafka but are dropped by the consumer kafka_to_adl.filter_records_without_mapping_id
because they have no abstract mapping in DIV1 -> null mapping_id -> excluded from the DS9
pres.legal_lease cache (mapping_id is the document grain). ES was patched to keep unmapped
leases (LND-8708 union-split); DS9 was not.

For the 10 affected WV Div1 LeaseIDs (Randolph 7c1984cb has no Div1 LeaseID and is excluded
upstream at the producer instead), count abstract mappings in DIV1.
  mapping_count = 0 -> zero-mapping -> dropped at DS9 (confirms hypothesis).
  mapping_count > 0 -> lease is mapped; absence has a different cause (check query_1 watermark).

Read-only. Run ON the countyScansTitle server (has the LinktoDiv1Repl linked server to DIV1).

VERIFY before running: DIV1 catalog name via the link is [Div1_Daily] (matches the producer's
own templates) and the mapping table is dbo.tblleaseAbstractMapping.
*/

;WITH affected(lease_id) AS (
    SELECT 4952552 UNION ALL   -- Braxton  3d44cb45
    SELECT 5210926 UNION ALL   -- Preston  386f3b84
    SELECT 4840326 UNION ALL   -- Preston  71b85e2b
    SELECT 4539306 UNION ALL   -- Preston  141ae74f
    SELECT 4493428 UNION ALL   -- Preston  5635d98f
    SELECT 5238497 UNION ALL   -- Randolph 47fd3773
    SELECT 4899098 UNION ALL   -- Randolph 5ba5b619
    SELECT 4508437 UNION ALL   -- Randolph 54e1a810
    SELECT 4580728 UNION ALL   -- Randolph 348c7efa
    SELECT 4954715             -- Upshur   cdb6b257
)
SELECT
    a.lease_id,
    COUNT(m.LeaseID) AS mapping_count,
    CASE WHEN COUNT(m.LeaseID) = 0
         THEN 'ZERO-MAPPING -> dropped at DS9 legal_lease'
         ELSE 'mapped -> should appear in DS9'
    END AS verdict
FROM affected a
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblleaseAbstractMapping] m
    ON m.LeaseID = a.lease_id
GROUP BY a.lease_id
ORDER BY mapping_count, a.lease_id;
