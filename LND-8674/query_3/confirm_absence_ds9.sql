/*
LND-8674 - Recent OH LegalLeases Not Published
Diagnostic query 3: confirm the affected LeaseIDs are absent from the DS9 legal_lease cache.

Sink table is pres.legal_lease (land-aws-glue kafka_to_adl arg legal_lease_table_name_base). Rows are
grained one-per-mapping_id but each carries lease_id (IntegerType), so an IN check works.

Read-only. Run against the DS9 database in SSMS.

Interpretation vs. query_2:
  ABSENT here + zero-mapping in query_2 -> confirmed: dropped at DS9 for null mapping_id (LND-8426 class).
  PRESENT here                          -> it IS published; re-check the customer's search / lease id.
*/

;WITH affected(lease_id) AS (
    SELECT 5185926 UNION ALL SELECT 4996359 UNION ALL SELECT 5191158 UNION ALL SELECT 5180672 UNION ALL
    SELECT 5205084 UNION ALL SELECT 4859233 UNION ALL SELECT 4859458 UNION ALL SELECT 4899128 UNION ALL
    SELECT 4937639 UNION ALL SELECT 5120740 UNION ALL SELECT 5222809 UNION ALL SELECT 4970359 UNION ALL
    SELECT 5120754 UNION ALL SELECT 5020243 UNION ALL SELECT 5077218 UNION ALL SELECT 4955678 UNION ALL
    SELECT 5194801 UNION ALL SELECT 5239151 UNION ALL SELECT 5272638 UNION ALL SELECT 5239283 UNION ALL
    SELECT 5230060 UNION ALL SELECT 5174648 UNION ALL SELECT 4966392 UNION ALL SELECT 5174593 UNION ALL
    SELECT 4966397 UNION ALL SELECT 4876680 UNION ALL SELECT 5174523 UNION ALL SELECT 4906804 UNION ALL
    SELECT 4966381 UNION ALL SELECT 4906938 UNION ALL SELECT 4907662 UNION ALL SELECT 4966383 UNION ALL
    SELECT 4906355 UNION ALL SELECT 5230862 UNION ALL SELECT 5214642 UNION ALL SELECT 5247783 UNION ALL
    SELECT 4854332 UNION ALL SELECT 5214488 UNION ALL SELECT 4826307 UNION ALL SELECT 5223734 UNION ALL
    SELECT 5224110 UNION ALL SELECT 5247954 UNION ALL SELECT 5223275 UNION ALL SELECT 5210917 UNION ALL
    SELECT 5229168 UNION ALL SELECT 5210875 UNION ALL SELECT 5239369 UNION ALL SELECT 5213574 UNION ALL
    SELECT 5214618
)
SELECT
    a.lease_id,
    CASE WHEN p.lease_id IS NULL THEN 'ABSENT' ELSE 'PRESENT' END AS ds9_publish_state,
    COUNT(p.lease_id) AS ds9_row_count
FROM affected a
LEFT JOIN [DS9].[pres].[legal_lease] p ON p.lease_id = a.lease_id
GROUP BY a.lease_id, CASE WHEN p.lease_id IS NULL THEN 'ABSENT' ELSE 'PRESENT' END
ORDER BY a.lease_id;

/*
ES cross-check: run query_4/es_legal_leases_presence_check.json against the legal-leases alias (not SSMS).
Post LND-8708 the ES union-split may keep unmapped leases -> PRESENT in ES while ABSENT in DS9 pins the
gap to "DS9 not yet patched." If ABSENT in BOTH (as in LND-8658), the 49 are missing from both sinks.
*/
