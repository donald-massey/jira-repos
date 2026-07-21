/* ============================================================================
   LND-6796 — Shape 2 dedupe of tblDimlXref (SELF-CONTAINED, dry-run first)
   ----------------------------------------------------------------------------
   Secondary issue: ~4,500 recordIDs each have TWO rows in
   [CS_Digital].[dbo].[tblDimlXref] carrying two different package_ids — a
   data-integrity defect (a record should map to one document, not two). There
   is no evidence this disrupts land-lease-producer: its control table
   [countyScansTitle].[dbo].[tblDataLoadersPerCounty].[LastProcessedDateLandLeaseProducer]
   advances for every county each run. This dedupe is the data-integrity fix.

   Fix: for each recordID with >1 xref row, keep exactly one row and delete the
   rest. Keeper selection per recordID:
     1. the row whose package_id is the artifact winner in #override, when present
        (the package with the more complete OCR+IIE artifacts — 20 records);
     2. otherwise the latest by (_ModifiedDateTime DESC, _CreatedDateTime DESC),
        with package_id ASC as a final deterministic tiebreak.

   SCOPE — DIML-confirmed same_pdf only. The DIML content check
   (LND-8451_diml_pdf_check.py -> shape2_pdf_compare.csv, 2026-06-30) classified
   the 4,500 pairs: 4,463 same_pdf / 12 different_pdf / 25 missing_pdf. The 37
   ambiguous (different_pdf + missing_pdf) are EXCLUDED via #exclude — they are
   all orphans (absent from tblRecord, so neither producer- nor COLE-relevant),
   and the 12 different_pdf are latent wrong-document rows that must be resolved,
   not silently collapsed. Do NOT run a blanket DELETE ... WHERE rn > 1 over all
   of tblDimlXref; this script is scoped strictly to the confirmed same_pdf set.

   This file is self-contained. The two inline lists below (37 exclusions + 20
   artifact overrides) are the ONLY per-record facts from the verdict CSV; the
   ~4,443 remaining same_pdf recordIDs fall back to latest _ModifiedDateTime and
   are derived at runtime, so no generated #keep population script is needed.

   RUN ORDER:
     Section 0  build #exclude + #override (inline, no writes to base tables)
     Section 1  build the dedupe plan (no writes)
     Section 2  DRY RUN previews (no writes)  <- review before Section 3
     Section 3  the DELETE (transactional; ROLLBACK by default — flip to COMMIT)
     Section 4  post-delete verification

   Run on DEV first. CS_Digital is a source DB — confirm the Section 2 counts
   match the verdict CSV's same_pdf tally before committing.
   ============================================================================ */


/* ---- Section 0: inline scope lists (no writes to base tables) ------------ */

-- 0a. #exclude — the 37 ambiguous recordIDs (different_pdf + missing_pdf) that
--     are NOT confirmed same_pdf. These are held out of the dedupe entirely.
IF OBJECT_ID('tempdb..#exclude') IS NOT NULL DROP TABLE #exclude;
CREATE TABLE #exclude (RecordID VARCHAR(50) PRIMARY KEY);

INSERT INTO #exclude (RecordID) VALUES
('0242c768-d613-11ea-b941-00505681224b'),  -- different_pdf
('024a1aca-d613-11ea-a049-00505681224b'),  -- different_pdf
('028fd9ec-d613-11ea-8249-00505681224b'),  -- missing_pdf
('029d481c-d613-11ea-8940-00505681224b'),  -- missing_pdf
('03640ca6-36c4-4f1c-856b-ae7310ba4bca'),  -- missing_pdf
('0b1a48c8-5fc6-400d-a9b1-2318d751e36d'),  -- missing_pdf
('138b0f5a-deb0-4199-9b8f-e8abb0ce0587'),  -- missing_pdf
('1BD95D62-EBDE-47AD-B768-8246EEB55AF7'),  -- different_pdf
('1d1ec971-2bba-4b66-8f9b-07c13ccbde9e'),  -- missing_pdf
('265e883e-f9a7-11eb-a812-00505681224b'),  -- missing_pdf
('288f8058-f9a7-11eb-b3f2-00505681224b'),  -- missing_pdf
('291d6c1a-f9a7-11eb-bef8-00505681224b'),  -- missing_pdf
('29b6c9d8-f9a7-11eb-9132-00505681224b'),  -- missing_pdf
('2bd3e371-31a5-4bce-8962-40a9e68f9ab8'),  -- missing_pdf
('2d2ddedc-f9a7-11eb-9803-00505681224b'),  -- missing_pdf
('2de31e08-3993-11e9-9625-00505681224b'),  -- missing_pdf
('2E92B891-F61B-4FA3-895A-2A8F85DBDD18'),  -- different_pdf
('44a73713-62e0-4542-9443-e7143d71830c'),  -- missing_pdf
('457fc413-6f04-43c4-a115-3688942f7a1c'),  -- missing_pdf
('4699FECD-E2E8-4035-A473-9114E357F3EF'),  -- different_pdf
('4ac507fb-518a-474d-9dd4-d8e2153b6d71'),  -- missing_pdf
('503ddeac-ae01-4626-bb99-319fac4d4cd2'),  -- missing_pdf
('5c4650b6-dc73-4abc-9221-d3cf23f011c6'),  -- missing_pdf
('74f3a8f3-8872-11eb-b7be-00505681224b'),  -- different_pdf
('882dc9ca-4a1e-4d80-afc4-efdb840977ba'),  -- missing_pdf
('8c41d240-9f0f-4ed4-b829-1bca14da544f'),  -- missing_pdf
('a632e022-f8de-11eb-899d-00505681224b'),  -- different_pdf
('a6aaf964-f8de-11eb-8cc1-00505681224b'),  -- different_pdf
('a711d426-f8de-11eb-979b-00505681224b'),  -- different_pdf
('a8c24e58-f8de-11eb-aee1-00505681224b'),  -- missing_pdf
('a9f7a1f0-f8de-11eb-8f87-00505681224b'),  -- missing_pdf
('ab2aab90-f8de-11eb-8dfa-00505681224b'),  -- missing_pdf
('ab9cad3e-68d8-11ea-a5d1-00505681224b'),  -- different_pdf
('E27C9C44-3B96-49CD-9DE9-CDFDD853DA09'),  -- different_pdf
('FA5477D7-4F96-42B5-87CD-E7F6CFFA3946'),  -- different_pdf
('fbae4e69-7c4e-448b-9f19-5ae5b4e65888'),  -- missing_pdf
('ffe02cb8-bdc9-43fe-9ee2-3be77be06b3c');  -- missing_pdf

-- 0b. #override — the 20 same_pdf recordIDs where one package had the more
--     complete OCR+IIE artifacts. keep_package_id wins over "latest" for these.
--     Every other same_pdf recordID has no artifact winner -> latest wins.
IF OBJECT_ID('tempdb..#override') IS NOT NULL DROP TABLE #override;
CREATE TABLE #override (RecordID VARCHAR(50) PRIMARY KEY, keep_package_id VARCHAR(50) NOT NULL);

INSERT INTO #override (RecordID, keep_package_id) VALUES
('3d373e66-7a56-11eb-97cf-00505681224b', 'c4epi40kqp4g00aarmog'),
('5bfc5754-288b-11e8-a39d-00505681224b', 'c4dtn9lnv8a0008h4ri0'),
('5c05dce8-288b-11e8-9e1d-00505681224b', 'c4dtn9kfjb0000cloosg'),
('5c083e4c-288b-11e8-aba5-00505681224b', 'c4dtn9lksi2g00c0njp0'),
('5c0d0118-288b-11e8-96e6-00505681224b', 'c4dtn9ic0ku000aosuug'),
('5c0f627a-288b-11e8-8f23-00505681224b', 'c4dtn9i11o1g008bpd0g'),
('5c1b4976-288b-11e8-8e0b-00505681224b', 'c4dtn9s7bhug00af6640'),
('5c30b602-288b-11e8-ab45-00505681224b', 'c4dtn9r0tnc000c7u0k0'),
('5c331766-288b-11e8-891c-00505681224b', 'c4dtn9rjknf000amgk20'),
('5c37da30-288b-11e8-abae-00505681224b', 'c4dtn9p6lb7g00cebsbg'),
('5c4fa824-288b-11e8-be5b-00505681224b', 'c4dtna7deto00089limg'),
('5c592db6-288b-11e8-8089-00505681224b', 'c4dtnabjknf000amgk30'),
('5c6514b0-288b-11e8-b1ea-00505681224b', 'c4dtnafdeto00089lin0'),
('5c6e9a46-288b-11e8-bdf7-00505681224b', 'c4dtna96lb7g00cebsc0'),
('5c70fba8-288b-11e8-8842-00505681224b', 'c4dtnaf2551g00d1auf0'),
('5c781fd8-288b-11e8-8ff7-00505681224b', 'c4dtnaa11o1g008bpd1g'),
('5c7f4408-288b-11e8-81b8-00505681224b', 'c4dtnaalpbg0009nnst0'),
('5c94b094-288b-11e8-b01a-00505681224b', 'c4dtnaj0tnc000c7u0l0'),
('5c9bd4c2-288b-11e8-b96e-00505681224b', 'c4dtnanorvtg00d03k40'),
('f635cdae-a198-11eb-9c6a-00505681224b', 'c4ephv3jknf000ams5vg');


/* ---- Section 1: build the dedupe plan (no writes) ------------------------ */
IF OBJECT_ID('tempdb..#dup')  IS NOT NULL DROP TABLE #dup;
IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;

-- recordIDs with >1 xref row (Shape 2), minus the 37 ambiguous. Materialized once.
SELECT x.RecordID
INTO #dup
FROM [CS_Digital].[dbo].[tblDimlXref] x
WHERE NOT EXISTS (SELECT 1 FROM #exclude e WHERE e.RecordID = x.RecordID)
GROUP BY x.RecordID
HAVING COUNT(*) > 1;
ALTER TABLE #dup ADD PRIMARY KEY (RecordID);

-- Rank each duplicate recordID's rows: rn = 1 is the keeper, the rest delete.
WITH ranked AS (
    SELECT
        x.RecordID,
        x.package_id,
        x._ModifiedDateTime,
        x._CreatedDateTime,
        o.keep_package_id,
        ROW_NUMBER() OVER (
            PARTITION BY x.RecordID
            ORDER BY
                CASE WHEN x.package_id = o.keep_package_id THEN 0 ELSE 1 END,  -- artifact winner first
                x._ModifiedDateTime DESC,                                      -- else latest wins
                x._CreatedDateTime DESC,
                x.package_id ASC                                               -- final deterministic tiebreak
        ) AS rn
    FROM [CS_Digital].[dbo].[tblDimlXref] x
    JOIN #dup d          ON d.RecordID = x.RecordID
    LEFT JOIN #override o ON o.RecordID = x.RecordID
)
SELECT RecordID, package_id, _ModifiedDateTime, _CreatedDateTime, keep_package_id,
       CASE WHEN rn = 1 THEN 'KEEP' ELSE 'DELETE' END AS action
INTO #plan
FROM ranked;

CREATE CLUSTERED INDEX ix_plan ON #plan (RecordID, package_id);


/* ---- Section 2: DRY RUN previews (no writes) ----------------------------- */

-- 2a. Records in scope, keepers, rows to delete. For clean Shape-2 pairs,
--     rows_to_delete should equal records_in_scope (one delete per record).
--     records_in_scope should be ~4,463 (the same_pdf tally).
SELECT
    COUNT(DISTINCT RecordID)                           AS records_in_scope,
    SUM(CASE WHEN action = 'KEEP'   THEN 1 ELSE 0 END) AS keepers,
    SUM(CASE WHEN action = 'DELETE' THEN 1 ELSE 0 END) AS rows_to_delete
FROM #plan;

-- 2b. Any recordID with more than two rows (data shows all = 2). Inspect if >0.
SELECT RecordID, COUNT(*) AS xref_rows
FROM #plan
GROUP BY RecordID
HAVING COUNT(*) <> 2;

-- 2c. Records where the artifact-preferred keep_package_id was NOT found among
--     the record's xref rows (would have fallen back to timestamp). Expect 0.
SELECT o.RecordID, o.keep_package_id
FROM #override o
JOIN #dup d ON d.RecordID = o.RecordID
WHERE NOT EXISTS (
    SELECT 1 FROM [CS_Digital].[dbo].[tblDimlXref] x
    WHERE x.RecordID = o.RecordID AND x.package_id = o.keep_package_id);

-- 2d. Sample of exactly what will be kept vs deleted (eyeball before committing).
SELECT TOP (100) RecordID, package_id, action, keep_package_id, _ModifiedDateTime, _CreatedDateTime
FROM #plan
ORDER BY RecordID, action;


/* ---- Section 3: the DELETE (transactional) ------------------------------- */
/* Review Section 2 first. Default is ROLLBACK so you can re-run safely.
   When the counts look right, change ROLLBACK to COMMIT and run this block. */
BEGIN TRAN;

    DELETE x
    FROM [CS_Digital].[dbo].[tblDimlXref] x
    JOIN #plan p ON p.RecordID = x.RecordID AND p.package_id = x.package_id
    WHERE p.action = 'DELETE';

    PRINT CONCAT('Rows deleted: ', @@ROWCOUNT,
                 ' (expected = rows_to_delete from 2a)');

ROLLBACK TRAN;   -- <<< change to COMMIT TRAN once the dry-run counts check out


/* ---- Section 4: post-delete verification (run AFTER committing) ---------- */
-- Every in-scope recordID should now have exactly one xref row. Expect 0 rows.
SELECT x.RecordID, COUNT(*) AS xref_rows
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #dup d ON d.RecordID = x.RecordID
GROUP BY x.RecordID
HAVING COUNT(*) <> 1;