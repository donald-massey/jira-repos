/*
LND-8674 - Recent OH LegalLeases Not Published
Diagnostic query 2 (PRIMARY / run first): abstract-mapping check.

Reframe after LND-8658 (WV) / LND-8426 (PA): query_1 traced only the PRODUCER path and labeled these
"behind_watermark_orphaned." That is the producer-side view. For the OH/PA/WV state group (StateID in
91,102,93) the real failure class is a CONSUMER-side drop: land-aws-glue kafka_to_adl.
filter_records_without_mapping_id excludes any lease with a null mapping_id, so it never lands in the
DS9 pres.legal_lease cache (mapping_id is the document grain) nor in ES legal-leases.

For OH, mapping_id is minted ONLY by div1_get_additional_fields.sql (StateID in 91,102,93), which reads
tblleaseAbstractMapping. A lease with no abstract mapping has null mapping_id and is dropped at the
consumer. query_1 already showed has_land_description = 0 for ALL 56 records -> strongly implies zero
abstract mapping. This query confirms it directly.

  mapping_count = 0 -> zero-mapping -> dropped at DS9/ES consumer (LND-8426 class). Root cause.
  mapping_count > 0 -> lease IS mapped; absence has a different cause (fall back to query_1 watermark).

Seeded with the 49 distinct Div1 LeaseIDs from the 53 query_1 "orphaned" rows (the 2 Summit NULL
Div1_LeaseID rows are cause 2 = excluded at producer; the 1 Cuyahoga StatusID=17 row is a correct
producer exclusion. Neither reaches Kafka, so neither is a consumer-drop candidate.)

Read-only. Run ON the countyScansTitle server (has the LinktoDiv1Repl linked server to DIV1).
VERIFY before running: DIV1 catalog via the link is [Div1_Daily] and the mapping table is
dbo.tblleaseAbstractMapping (matches the producer's own templates).
*/

;WITH affected(lease_id) AS (
    SELECT 5185926 UNION ALL   -- Cuyahoga   A6D2698B
    SELECT 4996359 UNION ALL   -- Cuyahoga   C578D644
    SELECT 5191158 UNION ALL   -- Cuyahoga   5E2501BF
    SELECT 5180672 UNION ALL   -- Cuyahoga   60061845
    SELECT 5205084 UNION ALL   -- Geauga     3ACBA175
    SELECT 4859233 UNION ALL   -- Geauga     1477DDF4 / FC809C5B
    SELECT 4859458 UNION ALL   -- Geauga     3DAF06C3 / 742F8ED1
    SELECT 4899128 UNION ALL   -- Geauga     F2D703B7
    SELECT 4937639 UNION ALL   -- Geauga     C4247E22
    SELECT 5120740 UNION ALL   -- Knox       1DCB44A7
    SELECT 5222809 UNION ALL   -- Knox       82124E04
    SELECT 4970359 UNION ALL   -- Knox       25C28606
    SELECT 5120754 UNION ALL   -- Knox       101D9D15
    SELECT 5020243 UNION ALL   -- Knox       B0FD4ABB
    SELECT 5077218 UNION ALL   -- Knox       F2CB51D0
    SELECT 4955678 UNION ALL   -- Lake       7A611B47
    SELECT 5194801 UNION ALL   -- Lake       648208E9
    SELECT 5239151 UNION ALL   -- Licking    B2CEF011
    SELECT 5272638 UNION ALL   -- Licking    5F7358A1
    SELECT 5239283 UNION ALL   -- Licking    EBBD4E26
    SELECT 5230060 UNION ALL   -- Licking    34527F42
    SELECT 5174648 UNION ALL   -- Medina     AD82622A
    SELECT 4966392 UNION ALL   -- Medina     CFE401DB
    SELECT 5174593 UNION ALL   -- Medina     81D64F59
    SELECT 4966397 UNION ALL   -- Medina     C5B82064
    SELECT 4876680 UNION ALL   -- Medina     A3C1319B
    SELECT 5174523 UNION ALL   -- Medina     C6B29032
    SELECT 4906804 UNION ALL   -- Medina     9BBA97CB
    SELECT 4966381 UNION ALL   -- Medina     C5BB47D5
    SELECT 4906938 UNION ALL   -- Medina     9761736D
    SELECT 4907662 UNION ALL   -- Medina     BFC2B272
    SELECT 4966383 UNION ALL   -- Medina     DC74A15E
    SELECT 4906355 UNION ALL   -- Medina     69CEDA59
    SELECT 5230862 UNION ALL   -- Muskingum  AEDC84B1
    SELECT 5214642 UNION ALL   -- Muskingum  89033C61
    SELECT 5247783 UNION ALL   -- Portage    64F9A5AB
    SELECT 4854332 UNION ALL   -- Summit     FBE43491 / D8880518 / ADBFA349
    SELECT 5214488 UNION ALL   -- Summit     7C0C755C
    SELECT 4826307 UNION ALL   -- Summit     3537FEA0
    SELECT 5223734 UNION ALL   -- Summit     DE4F564D
    SELECT 5224110 UNION ALL   -- Trumbull   8E64542B
    SELECT 5247954 UNION ALL   -- Trumbull   30C4FB84
    SELECT 5223275 UNION ALL   -- Trumbull   CA53A1EB
    SELECT 5210917 UNION ALL   -- Washington 3B86C028
    SELECT 5229168 UNION ALL   -- Washington F32296F0
    SELECT 5210875 UNION ALL   -- Washington 328F9327
    SELECT 5239369 UNION ALL   -- Washington E8A98740
    SELECT 5213574 UNION ALL   -- Washington E8FFE013
    SELECT 5214618             -- Wayne      7E087554
)
SELECT
    a.lease_id,
    COUNT(m.LeaseID) AS mapping_count,
    CASE WHEN COUNT(m.LeaseID) = 0
         THEN 'ZERO-MAPPING -> dropped at DS9/ES consumer'
         ELSE 'mapped -> should appear in DS9 (fall back to query_1 watermark)'
    END AS verdict
FROM affected a
LEFT JOIN [LinktoDiv1Repl].[Div1_Daily].[dbo].[tblleaseAbstractMapping] m
    ON m.LeaseID = a.lease_id
GROUP BY a.lease_id
ORDER BY mapping_count, a.lease_id;
