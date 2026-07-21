-- LND-6796: Primary issue (Shape 1) — orphaned tblDimlXref RecordIDs
-- https://enverus.atlassian.net/browse/LND-6796
--
-- The primary issue is that [CS_Digital].[dbo].[tblDimlXref] holds RecordIDs
-- under multi-record package_ids (the "65,148 package_ids with >1 xref row"
-- headline) that no longer exist in CS_Digital.dbo.tblRecord — their parent
-- records were hard-deleted and the xref rows were left behind. The cross-DB
-- check (LND-6796_orphan_tool.py check, 2026-07-02) found ~71,075 such
-- orphaned RecordIDs:
--     70,921 true orphans (absent from tblRecord in all three databases)
--        153 still present in countyScansTitle.dbo.tblRecord
--          1 still present in courthousedirecttitle.dbo.tblRecord
-- (65,148 is the package_id count, NOT the orphaned-RecordID count — the
--  RecordIDs number ~71,075.)
--
-- DELETE SCOPE (decision 2026-07-09): delete ONLY the 70,921 true orphans. The
-- 154 RecordIDs that are absent from CS_Digital.dbo.tblRecord but STILL EXIST in
-- a sibling DB (153 countyScansTitle + 1 courthousedirecttitle) are KEPT — their
-- CS_Digital xref rows are NOT removed. Queries 1 & 2 below only REVIEW those 154
-- on the sibling servers; nothing is deleted there. Section 1 on CS_Digital
-- excludes them from the delete set via the #keep list.
--
-- THREE SEPARATE SERVERS — each query runs on its OWN connection. There is no
-- linked server / three-part cross-server naming here:
--     CS_Digital            -> aus2-ch2-petl01v.na.drillinginfo.com     (Windows auth)
--     countyScansTitle      -> AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM       (Windows auth)
--     courthousedirecttitle -> chddb-prod...rds.amazonaws.com (AWS RDS)  (SQL auth)
-- Queries 1 and 2 embed their RecordID lists (from the orphan xdb results CSV)
-- because those servers cannot reach CS_Digital's tblDimlXref.
--
-- To EXPORT queries 1 & 2 to CSV (one per DB), run the companion script
-- LND-6796_orphan_tool.py export — it queries both servers and writes
-- LND-6796_orphans_countyScansTitle.csv and
-- LND-6796_orphans_courthousedirecttitle.csv. (A single SSMS window can't export
-- two different servers at once, hence the script.)
--
-- CASING / SCHEMA CAVEAT: queries 1 & 2 assume countyScansTitle and
-- courthousedirecttitle share CS_Digital's tblRecord / tblLookupCounties /
-- tblLookupStates schema and column casing. Verify against each DB before
-- running; drop any column a sibling DB does not have.


/* ============================================================================
   QUERY 1 — RUN ON countyScansTitle (AUS2-DTF-PAP01V) — REVIEW ONLY, NO DELETE
   The 153 CS_Digital-orphaned RecordIDs that still exist here. We are KEEPING
   these (their CS_Digital xref rows are not deleted); this pulls full record
   detail so their status can be reviewed. Nothing is modified on this server.
   ============================================================================ */
IF OBJECT_ID('tempdb..#cst_ids') IS NOT NULL DROP TABLE #cst_ids;
CREATE TABLE #cst_ids (RecordID VARCHAR(50) PRIMARY KEY);

INSERT INTO #cst_ids (RecordID) VALUES
('d1c02dfd-098c-4589-95e0-8706f55cedae'),
('a4254c00-0828-48bd-bf2a-9fda5febd8ab'),
('bb48cf67-94b2-42f0-b25b-49f2ba12bea0'),
('080ae8e8-1a67-46e5-94df-22dff6a0b9fa'),
('916487b1-181a-4949-8ff8-063e7b63ae93'),
('6dda1754-3da1-4031-9681-13f4f17ba274'),
('1b181013-4c52-49f8-b8b2-b9037f6e319f'),
('c6537094-6de4-4bc0-afff-916587f0910f'),
('6099ca86-255a-4247-aeff-f0b5352124ab'),
('b9002a36-3945-49e9-92e0-7588ba1fee89'),
('7b465a88-00e7-4bf7-b2a9-e72c6150c938'),
('641d8ef8-902a-457d-92c7-83bd9a97d4a0'),
('c1df66b9-0018-4010-b528-6245b12f6eaf'),
('7e81df06-f39f-4567-a20c-9ec31d98c4b5'),
('444d0d91-d778-4d3e-bbf1-2164ec47167f'),
('899ebbe6-5032-4698-8e83-f9b9a9df6ba2'),
('9c7912e5-d85f-4d61-b1b9-e4ef1289ade6'),
('a8ecbda4-26fc-4704-b25c-a144184e669b'),
('51f28b5f-aa58-4232-a994-9e8275e1d926'),
('e4d11477-e81c-485f-b404-77493ea6469b'),
('7cd8f634-edce-487c-a23f-bc3b767a913d'),
('4c906f1a-107c-42e7-a452-a5f0d7d1c037'),
('92b1432f-2887-451b-8bc9-af0b738b79d2'),
('60cb8800-cd08-4038-bb91-f465cd81201b'),
('20aaebc1-c082-4b76-9f2a-aad6552b3c31'),
('30a9617c-8708-4be8-9f65-e9411996dbdd'),
('dc88b7f9-ebf2-4250-9828-e4c5dc72f645'),
('359013e4-e9a2-484c-a983-3b0cb28e6026'),
('b32e18f4-6962-4680-83b4-1419f8ad6e64'),
('c726bd8a-de11-45b7-b38e-d3d6f953d912'),
('f9148e80-2498-480f-b146-9689bd6020bb'),
('33152dbd-35ed-4f03-960c-41cf66852717'),
('2786012d-a4a7-42df-94d6-7f9c49f4d9d3'),
('988046af-8be3-4a16-8885-fcf35615d8ba'),
('3a100ddd-c366-480b-896d-af43a8e07d5d'),
('a9a930e0-fcaf-4e18-8386-ac6dc5b51c44'),
('07dd15c9-7cd1-40c3-ace2-52a5703550b2'),
('53fd43dd-0b60-4800-89f4-4080cd8ea28a'),
('ba332421-6bb1-4168-9a52-ae0a40e1b0c5'),
('a61759c1-f6ea-4795-8de2-7065336025e2'),
('81b7c039-1238-4dd6-817d-050074ba2f73'),
('9bfbf764-0f83-4311-b5fd-eb83e53c47f4'),
('1cc9f891-e276-4a06-97ab-a0d813526b73'),
('511f2b8b-9786-49cd-bc40-ba992161aec6'),
('e7033cfe-90a9-4b4e-a386-3d291d82530b'),
('48926f97-83fd-44c1-b77d-049263e239f6'),
('c4609ba1-f2ef-497d-93be-90dc5432e489'),
('d7b99428-062c-4967-a9cc-5d1e8d299501'),
('156b0c2e-eb66-4fbb-ba6f-a984525693ff'),
('98c926ca-4763-4c22-bf9c-c70d680e5772'),
('f0d29b9b-d988-4367-a28c-43693a70f70d'),
('fe4160ba-8f8d-43de-b8b0-dbca407dc876'),
('f08c7bca-c159-4b6b-b2f0-eff1f51e4ef8'),
('90b018e0-c545-491f-9349-4559837a039f'),
('539dd7cb-761d-4781-a589-1b5dd391c6c5'),
('8f090c8f-b063-40af-ad12-f7acf4658fec'),
('d51dae5a-67da-4d34-adfa-4184c08a4626'),
('9ba23835-12e9-4331-9b79-b73ee1c88201'),
('a7ca5556-3a3a-4bcc-a967-0e5035e05f6d'),
('a6135687-3f9e-4377-bc44-23f9789f9b4a'),
('21fd9098-8da3-4afa-ae14-9998c259f79f'),
('cd8118df-479d-4264-a9cf-30f878204e52'),
('80e0350f-28cd-471b-bb28-496357582acc'),
('39f87808-194a-4a15-bd8d-0be20ba8adcb'),
('99ba178e-4f3a-4fe7-96e0-240ae3e822ed'),
('1084227d-4e89-47be-a70e-4847263ba900'),
('e7b5f97b-d28c-4c02-a4c6-4fc97cccfc31'),
('62ca3eb7-5832-454a-9430-194322d4f2b2'),
('fc25d50f-d151-4185-a10e-04a5b2537354'),
('b3227f34-1160-4c7b-be6c-198496756d79'),
('12f607b7-795c-40d2-aa57-81421694885c'),
('ef1041bd-af04-469e-836d-4e7cc35574b7'),
('2bed5437-7032-48cd-8d42-664214fe8e96'),
('11318ef5-355d-4366-a97a-ad8bb6819ab1'),
('8df3f580-2f17-4ef4-a651-a016aef7ca20'),
('453dfbb3-4979-405f-8f26-540cb31d65c1'),
('321dcfd1-45d5-420b-8346-ec7f8eda1bd2'),
('b1564891-492e-4986-9894-ca654d92261d'),
('058fa9be-f621-4ceb-bbcc-5a1ac53bb350'),
('8afa85c4-8b6c-48ae-baba-e800bae06434'),
('83a60b3d-d17b-4611-b4bd-86a78963a8d8'),
('a8e11c3b-0fed-4b97-9d2f-400b85c86d33'),
('41e949e8-491c-41f0-a0d0-5d9dca8101aa'),
('a01b9e79-69e2-4ce7-8b0f-b9694c9e8dc3'),
('13401781-febd-4950-bf2c-8b499cadd261'),
('0e350e4e-ffa4-4bf5-806c-28b610fc00d3'),
('a9c952c5-deb5-4291-8fef-7267511f533e'),
('6d627a83-ff26-4e7d-8029-4a40414f851d'),
('40eb2672-0aad-44e4-8265-f03eaafde002'),
('bdb9069b-9bcf-49e3-ac15-b8ce35212ea9'),
('8df40fd7-55fb-4cb9-b681-0b977bfb3c78'),
('0d5d5f6e-6d17-4287-9061-8b8e14807083'),
('64a9abe2-0636-4ce6-8622-e4f69ea8194d'),
('1c95cbba-7502-45a1-8529-117de9b49ba9'),
('11416f93-3ad0-4bbc-a733-c67b52b3b151'),
('9b40a78b-03f2-4637-8615-f98bc3adb0f7'),
('d5393b43-aeb2-42c8-94f8-483cc0512bd8'),
('96e4d83d-97b4-4b8d-9806-c96db03da440'),
('c74e0e85-2921-4097-ad02-b23395c3b7c9'),
('7eae886d-14fd-4840-96f3-84962b77ee08'),
('b45a43a2-a66e-43e0-9278-aee9be38860d'),
('655c59cf-d2d3-425a-b370-aa8808c8c725'),
('7c279a48-a6cc-4910-9603-8a2b0530263e'),
('0f77bdf9-90cc-4bd1-8fef-0c70b21bbc10'),
('7104b862-7e9a-43cd-8e76-272e10707a42'),
('1d11771e-b14f-4e5c-a136-8f2e27b17da6'),
('472d81b4-84b3-49d3-9b95-5dc4468a2034'),
('32a8e4cc-7ae3-4e59-bef1-b454a39e1320'),
('c40b4efb-4fcd-4d70-8d9f-22ce246f6be3'),
('391e72f1-aeb8-4aa2-a769-b9b32276233a'),
('d9328732-4264-40e9-b05c-c86f6cb07f4e'),
('1c1faefe-f47f-40c4-9c73-9068435dc3c4'),
('5a479176-8c0f-45c2-9165-c6052826d8c8'),
('8efddac2-bea4-4d3c-9b7e-f6aaea0e250f'),
('e1075324-ed03-4c99-b15d-15f5061c4397'),
('ca3dac5b-3642-4427-bf46-08096ed9aa27'),
('6b308da1-19f7-43b4-a4a0-38b09e81685a'),
('a6bb9286-f27f-408c-9d4f-89f70b9ffbbc'),
('8ba917c8-698c-4203-91b5-2af8650a8338'),
('28da9045-7b35-40ea-9405-1bda33c7e4a0'),
('5f687f80-4b47-4fcd-a48e-e1de8dc61272'),
('3600b21f-99d0-4123-b91f-a14d262fb894'),
('f5e2c4f0-a8f4-4856-945c-6ab542a6fd2e'),
('045a18d4-50ad-4b90-ad73-eecd21ca2cc0'),
('36267f5a-8db7-4570-9628-d0f5e52c9caf'),
('3b595f4d-3669-4e51-93a3-b73698442389'),
('1068dce8-0c53-4bcf-87ea-2eec8d3ebf85'),
('c6cd3138-da4b-4713-b3ce-d2c21282b163'),
('56d35442-56f0-4dc7-845d-c991f4c363e5'),
('95f7a9c5-f9ac-4486-8652-9258e77474c8'),
('ed65fae2-a5da-4781-a40d-b7dab7c7ed57'),
('b234e693-15ca-4c40-85c4-bbe4192c47fd'),
('aeda5113-e1c7-4d3f-adc3-f82808cfdd4e'),
('8aa023b8-6ade-4515-9883-04fe1d02095d'),
('9ccd51c2-c1e0-40a2-afa9-a3297415551d'),
('83abded8-16c5-4465-998f-17b0106ceedb'),
('a2de1dbb-f49f-4f37-8c3d-8d40324cd645'),
('5ca1d807-47ee-40eb-8cda-e59fa577567b'),
('7b3c4bf1-884a-4a1b-9e8f-fc653c1dc7bc'),
('c1f3a0f7-e995-4a65-8585-aee99504fd77'),
('aa18dcf4-246a-4cc3-94b8-6e9bc1810a30'),
('568a9055-64d9-4e17-bfd4-2da46b84c01d'),
('3deace98-c723-471e-84b2-ee7fc76aa42e'),
('1de1224e-2ffe-4c40-b868-11ed7d50b14f'),
('62985a21-be98-4581-b388-fa621b70f24b'),
('eb9984c6-9a94-4646-bd84-d8a331fe2b5a'),
('6027dd53-a757-466c-b312-b81d0ab8ec74'),
('b78bef1a-a213-43ce-9dae-1d6d43a18db2'),
('52d741e6-9a46-49a5-a88d-cdae5b23b586'),
('12b23a3a-e466-4cf9-80bc-98ceb1592a00'),
('a076178b-08e4-4c7a-8612-a8b428f67d0d'),
('f2a5bded-aa36-4007-b252-390afec00f0b'),
('9752fa15-0bcd-4192-9fc6-f008c41357a8');

SELECT
    r.recordID,
    r.CountyID,
    lc.CountyName,
    ls.StateAbbreviation,
    r.recordNumber,
    r.fileDate,
    r.statusID,
	ts.dataEntryDescription,
    r.originalFileName,
    r.storageFilePath
FROM #cst_ids i
JOIN [countyScansTitle].[dbo].[tblRecord] r          ON r.recordID = i.RecordID
LEFT JOIN [countyScansTitle].[dbo].[tblLookupCounties] lc ON lc.CountyID = r.CountyID
LEFT JOIN [countyScansTitle].[dbo].[tblLookupStates]   ls ON ls.StateID  = lc.StateID
LEFT JOIN [countyScansTitle].[dbo].[tblStatus]         ts ON ts.statusID = r.statusID
ORDER BY r.CountyID, r.recordID;


/* ============================================================================
   QUERY 2 — RUN ON courthousedirecttitle (chddb-prod...) — REVIEW ONLY, NO DELETE
   The single CS_Digital-orphaned RecordID that still exists here. We are KEEPING
   it (its CS_Digital xref row is not deleted); this is review only. Nothing is
   modified on this server.
   ============================================================================ */
IF OBJECT_ID('tempdb..#chd_ids') IS NOT NULL DROP TABLE #chd_ids;
CREATE TABLE #chd_ids (RecordID VARCHAR(50) PRIMARY KEY);

INSERT INTO #chd_ids (RecordID) VALUES
('b981a9bc-c4b6-4b51-b17d-e58b2833b950');

SELECT
    r.recordID,
    r.CountyID,
    lc.CountyName,
    ls.StateAbbreviation,
    r.recordNumber,
    r.fileDate,
    r.statusID,
    r.originalFileName,
    r.storageFilePath
FROM #chd_ids i
JOIN [courthousedirecttitle].[dbo].[tblRecord] r          ON r.recordID = i.RecordID
LEFT JOIN [courthousedirecttitle].[dbo].[tblLookupCounties] lc ON lc.CountyID = r.CountyID
LEFT JOIN [courthousedirecttitle].[dbo].[tblLookupStates]   ls ON ls.StateID  = lc.StateID
ORDER BY r.CountyID, r.recordID;


/* ============================================================================
   QUERY 3 — RUN ON CS_Digital (aus2-ch2-petl01v) — DELETE the orphaned xref rows
   ----------------------------------------------------------------------------
   Deletes every tblDimlXref row whose RecordID is under a multi-record
   package_id and is absent from CS_Digital.dbo.tblRecord, EXCLUDING the 154 that
   still exist in a sibling DB. Net delete set = the 70,921 true orphans.

   SCOPE (decision 2026-07-09): the 154 RecordIDs present in countyScansTitle
   (153) / courthousedirecttitle (1) — surfaced by queries 1 & 2 — are KEPT.
   Section 1 loads them into #keep and excludes them from #orphans, so their
   CS_Digital xref rows are NOT deleted.

   Dry-run first: the DELETE runs in a transaction that defaults to ROLLBACK.
   Review the Section 2 counts, then flip ROLLBACK -> COMMIT and re-run.
   Run on DEV first; CS_Digital is a source DB.
   ============================================================================ */

/* ---- Section 0: SURVIVING records under the affected package_ids (review) --
   ----------------------------------------------------------------------------
   The counterpart to the Section 1b backup: what STAYS, not what goes. These
   are the live records still bound to the multi-record package_ids after the
   orphan delete — recordIDs under a package_id with >1 xref row that DO exist
   in CS_Digital.dbo.tblRecord. Section 3 does not touch them. Review this to
   confirm every affected package_id still keeps a valid live binding once the
   orphaned rows are removed.

   No writes. Ordered by package_id so each package's survivors group together.
   Volume note: this returns every live record under a shared package_id (order
   tens of thousands). To spot-check instead, add a WHERE on x.package_id.
   -------------------------------------------------------------------------- */
WITH multi_pkg AS (
    SELECT package_id
    FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY package_id
    HAVING COUNT(*) > 1
)
SELECT
    x.package_id,
    r.recordID,
    r.CountyID,
    lc.CountyName,
    ls.StateAbbreviation,
    r.recordNumber,
    r.fileDate,
    r.statusID,
    r.originalFileName,
    r.storageFilePath
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN multi_pkg m                                    ON m.package_id = x.package_id
JOIN [CS_Digital].[dbo].[tblRecord] r               ON r.recordID = x.RecordID
LEFT JOIN [CS_Digital].[dbo].[tblLookupCounties] lc ON lc.CountyID = r.CountyID
LEFT JOIN [CS_Digital].[dbo].[tblLookupStates]   ls ON ls.StateID  = lc.StateID
ORDER BY x.package_id, r.recordID;

/* ---- Section 1: build the orphan set (no writes) ------------------------- */
IF OBJECT_ID('tempdb..#orphans') IS NOT NULL DROP TABLE #orphans;
IF OBJECT_ID('tempdb..#keep')    IS NOT NULL DROP TABLE #keep;

-- The 154 RecordIDs to KEEP: absent from CS_Digital.dbo.tblRecord but still
-- present in a sibling DB (153 countyScansTitle + 1 courthousedirecttitle, the
-- same IDs surfaced by queries 1 & 2). Their CS_Digital xref rows are excluded
-- from the delete below. Sourced from LND-6796_shape1_orphan_xdb_results.csv
-- (verdict found_in_countyScansTitle / found_in_courthousedirecttitle).
CREATE TABLE #keep (RecordID VARCHAR(50) PRIMARY KEY);
INSERT INTO #keep (RecordID) VALUES
-- 153 in countyScansTitle
('d1c02dfd-098c-4589-95e0-8706f55cedae'),
('a4254c00-0828-48bd-bf2a-9fda5febd8ab'),
('bb48cf67-94b2-42f0-b25b-49f2ba12bea0'),
('080ae8e8-1a67-46e5-94df-22dff6a0b9fa'),
('916487b1-181a-4949-8ff8-063e7b63ae93'),
('6dda1754-3da1-4031-9681-13f4f17ba274'),
('1b181013-4c52-49f8-b8b2-b9037f6e319f'),
('c6537094-6de4-4bc0-afff-916587f0910f'),
('6099ca86-255a-4247-aeff-f0b5352124ab'),
('b9002a36-3945-49e9-92e0-7588ba1fee89'),
('7b465a88-00e7-4bf7-b2a9-e72c6150c938'),
('641d8ef8-902a-457d-92c7-83bd9a97d4a0'),
('c1df66b9-0018-4010-b528-6245b12f6eaf'),
('7e81df06-f39f-4567-a20c-9ec31d98c4b5'),
('444d0d91-d778-4d3e-bbf1-2164ec47167f'),
('899ebbe6-5032-4698-8e83-f9b9a9df6ba2'),
('9c7912e5-d85f-4d61-b1b9-e4ef1289ade6'),
('a8ecbda4-26fc-4704-b25c-a144184e669b'),
('51f28b5f-aa58-4232-a994-9e8275e1d926'),
('e4d11477-e81c-485f-b404-77493ea6469b'),
('7cd8f634-edce-487c-a23f-bc3b767a913d'),
('4c906f1a-107c-42e7-a452-a5f0d7d1c037'),
('92b1432f-2887-451b-8bc9-af0b738b79d2'),
('60cb8800-cd08-4038-bb91-f465cd81201b'),
('20aaebc1-c082-4b76-9f2a-aad6552b3c31'),
('30a9617c-8708-4be8-9f65-e9411996dbdd'),
('dc88b7f9-ebf2-4250-9828-e4c5dc72f645'),
('359013e4-e9a2-484c-a983-3b0cb28e6026'),
('b32e18f4-6962-4680-83b4-1419f8ad6e64'),
('c726bd8a-de11-45b7-b38e-d3d6f953d912'),
('f9148e80-2498-480f-b146-9689bd6020bb'),
('33152dbd-35ed-4f03-960c-41cf66852717'),
('2786012d-a4a7-42df-94d6-7f9c49f4d9d3'),
('988046af-8be3-4a16-8885-fcf35615d8ba'),
('3a100ddd-c366-480b-896d-af43a8e07d5d'),
('a9a930e0-fcaf-4e18-8386-ac6dc5b51c44'),
('07dd15c9-7cd1-40c3-ace2-52a5703550b2'),
('53fd43dd-0b60-4800-89f4-4080cd8ea28a'),
('ba332421-6bb1-4168-9a52-ae0a40e1b0c5'),
('a61759c1-f6ea-4795-8de2-7065336025e2'),
('81b7c039-1238-4dd6-817d-050074ba2f73'),
('9bfbf764-0f83-4311-b5fd-eb83e53c47f4'),
('1cc9f891-e276-4a06-97ab-a0d813526b73'),
('511f2b8b-9786-49cd-bc40-ba992161aec6'),
('e7033cfe-90a9-4b4e-a386-3d291d82530b'),
('48926f97-83fd-44c1-b77d-049263e239f6'),
('c4609ba1-f2ef-497d-93be-90dc5432e489'),
('d7b99428-062c-4967-a9cc-5d1e8d299501'),
('156b0c2e-eb66-4fbb-ba6f-a984525693ff'),
('98c926ca-4763-4c22-bf9c-c70d680e5772'),
('f0d29b9b-d988-4367-a28c-43693a70f70d'),
('fe4160ba-8f8d-43de-b8b0-dbca407dc876'),
('f08c7bca-c159-4b6b-b2f0-eff1f51e4ef8'),
('90b018e0-c545-491f-9349-4559837a039f'),
('539dd7cb-761d-4781-a589-1b5dd391c6c5'),
('8f090c8f-b063-40af-ad12-f7acf4658fec'),
('d51dae5a-67da-4d34-adfa-4184c08a4626'),
('9ba23835-12e9-4331-9b79-b73ee1c88201'),
('a7ca5556-3a3a-4bcc-a967-0e5035e05f6d'),
('a6135687-3f9e-4377-bc44-23f9789f9b4a'),
('21fd9098-8da3-4afa-ae14-9998c259f79f'),
('cd8118df-479d-4264-a9cf-30f878204e52'),
('80e0350f-28cd-471b-bb28-496357582acc'),
('39f87808-194a-4a15-bd8d-0be20ba8adcb'),
('99ba178e-4f3a-4fe7-96e0-240ae3e822ed'),
('1084227d-4e89-47be-a70e-4847263ba900'),
('e7b5f97b-d28c-4c02-a4c6-4fc97cccfc31'),
('62ca3eb7-5832-454a-9430-194322d4f2b2'),
('fc25d50f-d151-4185-a10e-04a5b2537354'),
('b3227f34-1160-4c7b-be6c-198496756d79'),
('12f607b7-795c-40d2-aa57-81421694885c'),
('ef1041bd-af04-469e-836d-4e7cc35574b7'),
('2bed5437-7032-48cd-8d42-664214fe8e96'),
('11318ef5-355d-4366-a97a-ad8bb6819ab1'),
('8df3f580-2f17-4ef4-a651-a016aef7ca20'),
('453dfbb3-4979-405f-8f26-540cb31d65c1'),
('321dcfd1-45d5-420b-8346-ec7f8eda1bd2'),
('b1564891-492e-4986-9894-ca654d92261d'),
('058fa9be-f621-4ceb-bbcc-5a1ac53bb350'),
('8afa85c4-8b6c-48ae-baba-e800bae06434'),
('83a60b3d-d17b-4611-b4bd-86a78963a8d8'),
('a8e11c3b-0fed-4b97-9d2f-400b85c86d33'),
('41e949e8-491c-41f0-a0d0-5d9dca8101aa'),
('a01b9e79-69e2-4ce7-8b0f-b9694c9e8dc3'),
('13401781-febd-4950-bf2c-8b499cadd261'),
('0e350e4e-ffa4-4bf5-806c-28b610fc00d3'),
('a9c952c5-deb5-4291-8fef-7267511f533e'),
('6d627a83-ff26-4e7d-8029-4a40414f851d'),
('40eb2672-0aad-44e4-8265-f03eaafde002'),
('bdb9069b-9bcf-49e3-ac15-b8ce35212ea9'),
('8df40fd7-55fb-4cb9-b681-0b977bfb3c78'),
('0d5d5f6e-6d17-4287-9061-8b8e14807083'),
('64a9abe2-0636-4ce6-8622-e4f69ea8194d'),
('1c95cbba-7502-45a1-8529-117de9b49ba9'),
('11416f93-3ad0-4bbc-a733-c67b52b3b151'),
('9b40a78b-03f2-4637-8615-f98bc3adb0f7'),
('d5393b43-aeb2-42c8-94f8-483cc0512bd8'),
('96e4d83d-97b4-4b8d-9806-c96db03da440'),
('c74e0e85-2921-4097-ad02-b23395c3b7c9'),
('7eae886d-14fd-4840-96f3-84962b77ee08'),
('b45a43a2-a66e-43e0-9278-aee9be38860d'),
('655c59cf-d2d3-425a-b370-aa8808c8c725'),
('7c279a48-a6cc-4910-9603-8a2b0530263e'),
('0f77bdf9-90cc-4bd1-8fef-0c70b21bbc10'),
('7104b862-7e9a-43cd-8e76-272e10707a42'),
('1d11771e-b14f-4e5c-a136-8f2e27b17da6'),
('472d81b4-84b3-49d3-9b95-5dc4468a2034'),
('32a8e4cc-7ae3-4e59-bef1-b454a39e1320'),
('c40b4efb-4fcd-4d70-8d9f-22ce246f6be3'),
('391e72f1-aeb8-4aa2-a769-b9b32276233a'),
('d9328732-4264-40e9-b05c-c86f6cb07f4e'),
('1c1faefe-f47f-40c4-9c73-9068435dc3c4'),
('5a479176-8c0f-45c2-9165-c6052826d8c8'),
('8efddac2-bea4-4d3c-9b7e-f6aaea0e250f'),
('e1075324-ed03-4c99-b15d-15f5061c4397'),
('ca3dac5b-3642-4427-bf46-08096ed9aa27'),
('6b308da1-19f7-43b4-a4a0-38b09e81685a'),
('a6bb9286-f27f-408c-9d4f-89f70b9ffbbc'),
('8ba917c8-698c-4203-91b5-2af8650a8338'),
('28da9045-7b35-40ea-9405-1bda33c7e4a0'),
('5f687f80-4b47-4fcd-a48e-e1de8dc61272'),
('3600b21f-99d0-4123-b91f-a14d262fb894'),
('f5e2c4f0-a8f4-4856-945c-6ab542a6fd2e'),
('045a18d4-50ad-4b90-ad73-eecd21ca2cc0'),
('36267f5a-8db7-4570-9628-d0f5e52c9caf'),
('3b595f4d-3669-4e51-93a3-b73698442389'),
('1068dce8-0c53-4bcf-87ea-2eec8d3ebf85'),
('c6cd3138-da4b-4713-b3ce-d2c21282b163'),
('56d35442-56f0-4dc7-845d-c991f4c363e5'),
('95f7a9c5-f9ac-4486-8652-9258e77474c8'),
('ed65fae2-a5da-4781-a40d-b7dab7c7ed57'),
('b234e693-15ca-4c40-85c4-bbe4192c47fd'),
('aeda5113-e1c7-4d3f-adc3-f82808cfdd4e'),
('8aa023b8-6ade-4515-9883-04fe1d02095d'),
('9ccd51c2-c1e0-40a2-afa9-a3297415551d'),
('83abded8-16c5-4465-998f-17b0106ceedb'),
('a2de1dbb-f49f-4f37-8c3d-8d40324cd645'),
('5ca1d807-47ee-40eb-8cda-e59fa577567b'),
('7b3c4bf1-884a-4a1b-9e8f-fc653c1dc7bc'),
('c1f3a0f7-e995-4a65-8585-aee99504fd77'),
('aa18dcf4-246a-4cc3-94b8-6e9bc1810a30'),
('568a9055-64d9-4e17-bfd4-2da46b84c01d'),
('3deace98-c723-471e-84b2-ee7fc76aa42e'),
('1de1224e-2ffe-4c40-b868-11ed7d50b14f'),
('62985a21-be98-4581-b388-fa621b70f24b'),
('eb9984c6-9a94-4646-bd84-d8a331fe2b5a'),
('6027dd53-a757-466c-b312-b81d0ab8ec74'),
('b78bef1a-a213-43ce-9dae-1d6d43a18db2'),
('52d741e6-9a46-49a5-a88d-cdae5b23b586'),
('12b23a3a-e466-4cf9-80bc-98ceb1592a00'),
('a076178b-08e4-4c7a-8612-a8b428f67d0d'),
('f2a5bded-aa36-4007-b252-390afec00f0b'),
('9752fa15-0bcd-4192-9fc6-f008c41357a8'),
-- 1 in courthousedirecttitle
('b981a9bc-c4b6-4b51-b17d-e58b2833b950');

WITH multi_pkg AS (
    SELECT package_id
    FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY package_id
    HAVING COUNT(*) > 1
)
SELECT DISTINCT x.RecordID
INTO #orphans
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN multi_pkg m ON m.package_id = x.package_id
WHERE NOT EXISTS (
    SELECT 1
    FROM [CS_Digital].[dbo].[tblRecord] r
    WHERE r.recordID = x.RecordID
)
AND NOT EXISTS (
    SELECT 1
    FROM #keep k
    WHERE k.RecordID = x.RecordID
);

CREATE CLUSTERED INDEX ix_orphans ON #orphans (RecordID);

/* ---- Section 1b: BACKUP the exact rows to be deleted (run BEFORE the DELETE)
   ----------------------------------------------------------------------------
   Full-fidelity backup of every tblDimlXref row this script will delete. Run
   this SELECT and save the result set as CSV (with header) to:
       backup/LND-6796_shape1_deleted_xref_backup.csv
   SELECT x.* captures ALL columns of tblDimlXref (RecordID, package_id, and the
   load timestamps _CreatedDateTime/_ModifiedDateTime) so the deleted rows can be
   re-created exactly if a restore is ever needed. This is the authoritative
   backup — it is taken from the live table at delete time, so it is provably
   identical to the deletion set. (LND-6796_shape1_orphans.csv from the research
   query holds the RecordID<->package_id pairs but not the full rows.)

   Because #orphans now EXCLUDES the 154 kept RecordIDs, this backup covers only
   the ~70,921 true orphans. Sanity check: this SELECT's row count MUST equal
   rows_to_delete from 2a (expect ~70,921). NOTE: the committed backup CSV has
   been filtered to exactly the 70,921-row deletion set (the 154 kept RecordIDs
   were removed), so it already matches. Re-run this SELECT at delete time to
   confirm it still matches the live table.
   -------------------------------------------------------------------------- */
SELECT x.*
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #orphans o ON o.RecordID = x.RecordID
ORDER BY x.RecordID;

/* ---- Section 2: DRY RUN previews (no writes) ----------------------------- */
-- 2a. Orphaned RecordIDs and the xref rows they own (154 kept excluded).
--     orphaned_recordIDs should be ~70,921; rows_to_delete >= that (a RecordID
--     can own >1 xref row).
SELECT
    (SELECT COUNT(*) FROM #orphans)                    AS orphaned_recordIDs,
    COUNT(*)                                           AS rows_to_delete
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #orphans o ON o.RecordID = x.RecordID;

-- 2b. Sample of exactly what will be deleted.
SELECT TOP (100) x.RecordID, x.package_id
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #orphans o ON o.RecordID = x.RecordID
ORDER BY x.RecordID;

/* ---- Section 3: the DELETE (transactional) ------------------------------- */
/* Review Section 2 first. Default is ROLLBACK so you can re-run safely.
   When the counts look right, change ROLLBACK to COMMIT and run this block. */
BEGIN TRAN;

    DELETE x
    FROM [CS_Digital].[dbo].[tblDimlXref] x
    JOIN #orphans o ON o.RecordID = x.RecordID;

    PRINT CONCAT('Rows deleted: ', @@ROWCOUNT,
                 ' (expected = rows_to_delete from 2a)');

ROLLBACK TRAN;   -- <<< change to COMMIT TRAN once the dry-run counts check out

/* ---- Section 4: post-delete verification (run AFTER committing) ---------- */
-- 4a. Every deleted orphan should be gone from tblDimlXref. Expect 0.
SELECT COUNT(*) AS remaining_orphan_rows
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #orphans o ON o.RecordID = x.RecordID;

-- 4b. The 154 kept RecordIDs are intentionally still present — they remain
--     orphaned relative to CS_Digital.tblRecord by design (they live in a
--     sibling DB). Expect 154. This is NOT a failure; it documents the kept set.
SELECT COUNT(*) AS kept_rows_still_present
FROM [CS_Digital].[dbo].[tblDimlXref] x
JOIN #keep k ON k.RecordID = x.RecordID;