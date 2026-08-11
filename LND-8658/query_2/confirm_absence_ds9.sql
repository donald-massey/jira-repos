/*
LND-8658 - Recent WV LegalLeases Not Published
Diagnostic query 2: confirm the affected LeaseIDs are absent from the DS9 legal_lease cache.

Sink table is pres.legal_lease (from land-aws-glue kafka_to_adl job arg legal_lease_table_name_base).
The Glue job rotates suffixed tables via sp_rename, so the live view is pres.legal_lease.
Rows are grained one-per-mapping_id but each carries lease_id (IntegerType), so an IN check works.

Read-only. Run against the DS9 database in SSMS.

Interpretation vs. query_3:
  absent here + zero-mapping in query_3 -> confirmed: dropped at DS9 for null mapping_id (LND-8426 class).
  present here                          -> it IS published; re-check the customer's search / lease id.
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
    CASE WHEN p.lease_id IS NULL THEN 'ABSENT' ELSE 'PRESENT' END AS ds9_publish_state,
    COUNT(p.lease_id) AS ds9_row_count
FROM affected a
LEFT JOIN [DS9].[pres].[legal_lease] p ON p.lease_id = a.lease_id
GROUP BY a.lease_id, CASE WHEN p.lease_id IS NULL THEN 'ABSENT' ELSE 'PRESENT' END
ORDER BY a.lease_id;

/*
ES cross-check (post LND-8708, ES keeps unmapped leases so these may be PRESENT in ES while ABSENT
in DS9 -> pins the gap to "DS9 not yet patched with the union-split"). Run against the legal-leases
ES alias, not SSMS:
    GET legal-leases/_search
    { "query": { "terms": { "lease_id": [4952552,5210926,4840326,4539306,4493428,
                                          5238497,4899098,4508437,4580728,4954715] } },
      "_source": ["lease_id","mapping_id","county_parish","record_date"], "size": 50 }
*/
