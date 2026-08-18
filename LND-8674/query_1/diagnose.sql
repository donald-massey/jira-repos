/* ============================================================================
   LND-8674 : Recent OH LegalLeases Not Published -- per-record diagnosis
   ----------------------------------------------------------------------------
   READ-ONLY. Run on the CSTitle connection (database: countyScansTitle).
   Walks each of the 56 affected records through the land-lease-producer's
   publish gates, in producer order, and reports the FIRST gate each one fails.

   Gate sources (land-lease-producer):
     status/insttype/filedate/exportlog  -> cstitle_get_modified_instrument_ids.sql
     county_mapped (INNER JOIN)          -> cstitle_get_instruments.sql line 54  <-- top suspect
     exportlog CROSS APPLY               -> cstitle_get_instruments.sql line 55
     leaseid_numeric                     -> land_lease_producer.py:386 astype("int")
     watermark                           -> tblDataLoadersPerCounty.LastProcessedDateLandLeaseProducer
   ============================================================================ */

IF OBJECT_ID('tempdb..#affected') IS NOT NULL DROP TABLE #affected;
CREATE TABLE #affected (
    recordID     UNIQUEIDENTIFIER,
    div1_leaseID BIGINT NULL,
    county       VARCHAR(100) NULL
);

INSERT INTO #affected (recordID, div1_leaseID, county) VALUES
('0ccb1721-58fc-4c2f-8b05-122b05e456e3', 5182550, 'Cuyahoga'),
('5e2501bf-d6b0-4d99-a580-3688dff93c35', 5191158, 'Cuyahoga'),
('60061845-9cb5-4d5a-8c38-d6dc4a91d270', 5180672, 'Cuyahoga'),
('a6d2698b-bb84-41cf-a250-34451e934f93', 5185926, 'Cuyahoga'),
('c578d644-d58a-46fb-83a2-34a4604c56fa', 4996359, 'Cuyahoga'),
('1477ddf4-a678-437e-9b79-1b733450ed37', 4859233, 'Geauga'),
('3acba175-db0c-4d2e-8f69-14e407688177', 5205084, 'Geauga'),
('3daf06c3-6850-46f1-a4a4-805edfc75c6f', 4859458, 'Geauga'),
('742f8ed1-e673-4a11-abf5-f2880ea29b48', 4859458, 'Geauga'),
('c4247e22-5c05-4bfc-9252-dacbcdc8b17c', 4937639, 'Geauga'),
('f2d703b7-d9a9-47e4-8f96-8172b8c99ccd', 4899128, 'Geauga'),
('fc809c5b-ca67-4f51-ace7-789abe4f2db9', 4859233, 'Geauga'),
('101d9d15-3674-4fea-9c39-81c4d2451b6f', 5120754, 'Knox'),
('1dcb44a7-4b3a-4a88-8e8e-2e44bdabef30', 5120740, 'Knox'),
('25c28606-635a-46cb-a7ae-6f27d9dd5cf0', 4970359, 'Knox'),
('82124e04-2766-45c7-a56e-4ff171616d29', 5222809, 'Knox'),
('b0fd4abb-d83c-4d8a-a7cd-8eaa63ab9dec', 5020243, 'Knox'),
('f2cb51d0-942a-47d1-97d2-fb66b4f07962', 5077218, 'Knox'),
('648208e9-3da5-4708-a873-ca27eee1b699', 5194801, 'Lake'),
('7a611b47-07d1-41a5-b6a9-449e9c31b6aa', 4955678, 'Lake'),
('34527f42-9106-4f8c-9f86-a7dec55ab5dc', 5230060, 'Licking'),
('5f7358a1-69d6-43d5-b86c-3f4a1641c103', 5272638, 'Licking'),
('b2cef011-c1f5-4519-a39c-3086ce1b5f55', 5239151, 'Licking'),
('ebbd4e26-1843-4e94-a608-888fcca94bf9', 5239283, 'Licking'),
('69ceda59-b974-4678-8b7f-e8031cd44548', 4906355, 'Medina'),
('81d64f59-fc93-4696-83b6-45b15f874d16', 5174593, 'Medina'),
('9761736d-8e2d-46fa-9e50-dde9a9ea5c9b', 4906938, 'Medina'),
('9bba97cb-dad4-4f5c-8770-c49057b80a7b', 4906804, 'Medina'),
('a3c1319b-7a69-47ae-bdb8-8d53929fc3a9', 4876680, 'Medina'),
('ad82622a-0cc2-416f-a910-1b5a965323b3', 5174648, 'Medina'),
('bfc2b272-b346-47ec-8487-e0093d9ecebb', 4907662, 'Medina'),
('c5b82064-21b9-4327-826b-846d56edd6c8', 4966397, 'Medina'),
('c5bb47d5-f928-4cdf-b0d5-caf5741f6150', 4966381, 'Medina'),
('c6b29032-8429-4018-ae9f-b2325f3ee63e', 5174523, 'Medina'),
('cfe401db-0af5-4557-8c33-331114378013', 4966392, 'Medina'),
('dc74a15e-059c-454b-b503-e5cc3f670b08', 4966383, 'Medina'),
('89033c61-9af0-485a-b22a-8ab66a2b8ed2', 5214642, 'Muskingum'),
('aedc84b1-5f5f-4740-bc15-89726659d806', 5230862, 'Muskingum'),
('64f9a5ab-6b1e-49e1-a48a-3adb86c9005f', 5247783, 'Portage'),
('206f3472-a64a-44dc-9a5c-2f253a01a6d8', NULL, 'Summit'),
('3537fea0-34da-4747-ae0e-d5b1b0ce3b90', 4826307, 'Summit'),
('7c0c755c-2569-464e-bbfe-43ba823bf7af', 5214488, 'Summit'),
('adbfa349-8113-4525-bbf3-bcc25a6557b7', 4854332, 'Summit'),
('d8880518-d447-49a5-b40f-641dde9a40d5', 4854332, 'Summit'),
('de4f564d-2aed-4fe0-ab53-e6e93068a8bf', 5223734, 'Summit'),
('f1cab1be-d01a-4f42-bc98-584cc9c88995', NULL, 'Summit'),
('fbe43491-6af6-443d-af99-2e688d49eb99', 4854332, 'Summit'),
('30c4fb84-9bc0-4b58-b706-e70c9e87c9b4', 5247954, 'Trumbull'),
('8e64542b-bfae-4329-8763-c6db8fb75ee2', 5224110, 'Trumbull'),
('ca53a1eb-ec3b-4492-a178-f8adb8b49cb5', 5223275, 'Trumbull'),
('328f9327-65fd-423f-acdc-5c314d738191', 5210875, 'Washington'),
('3b86c028-ebd9-4645-a25b-40c3482a3ab5', 5210917, 'Washington'),
('e8a98740-fe57-471d-8ac2-73e60af5fd51', 5239369, 'Washington'),
('e8ffe013-9a70-4a43-b34a-f37ee4f063e7', 5213574, 'Washington'),
('f32296f0-2461-426d-bd8f-5908eb210be6', 5229168, 'Washington'),
('7e087554-e443-451b-ad3f-7c6578f923a7', 5214618, 'Wayne');

/* ---------- per-record gate report (one row per recordID) ---------- */
SELECT
    a.county,
    a.recordID,
    a.div1_leaseID,
    CASE WHEN R.recordID IS NULL THEN 0 ELSE 1 END                        AS record_exists,
    R.StatusID,
    CASE WHEN R.StatusID IN (4,10,16) THEN 1 ELSE 0 END                   AS status_ok,
    R.instrumentTypeID,
    CASE WHEN R.instrumentTypeID NOT IN ('ASN','MD') THEN 1 ELSE 0 END    AS insttype_ok,
    R.fileDate,
    CASE WHEN R.fileDate IS NOT NULL THEN 1 ELSE 0 END                    AS filedate_present,
    el.leaseID                                                            AS exportlog_leaseID,
    CASE WHEN el.leaseID IS NOT NULL THEN 1 ELSE 0 END                    AS exportlog_leaseid_ok,
    C.Div1CountyID,
    mcl.leasingID                                                         AS mcl_leasingID,
    CASE WHEN mcl.leasingID IS NOT NULL THEN 1 ELSE 0 END                 AS county_mapped,
    CASE WHEN TRY_CONVERT(BIGINT, CONVERT(VARCHAR(50), el.leaseID)) IS NOT NULL
         THEN 1 ELSE 0 END                                               AS leaseid_numeric,
    ISNULL(ld.land_desc_count, 0)                                         AS land_desc_count,
    CASE WHEN ISNULL(ld.land_desc_count,0) > 0 THEN 1 ELSE 0 END          AS has_land_description,
    dl.LastProcessedDateLandLeaseProducer                                 AS county_watermark,
    R.[_ModifiedDateTime]                                                 AS record_modified,
    el.[_ModifiedDateTime]                                                AS exportlog_modified,
    CASE WHEN R.[_ModifiedDateTime]  >= dl.LastProcessedDateLandLeaseProducer
           OR el.[_ModifiedDateTime] >= dl.LastProcessedDateLandLeaseProducer
         THEN 1 ELSE 0 END                                               AS in_window_last_run,
    /* verdict: first hard gate that fails, in producer order.
       NOTE: has_land_description is informational only -- a missing land
       description does NOT block publishing (LEFT-join enrichment). */
    CASE
        WHEN R.recordID IS NULL                       THEN '1_record_not_found'
        WHEN R.StatusID NOT IN (4,10,16)              THEN '2_status_excluded'
        WHEN R.instrumentTypeID IN ('ASN','MD')       THEN '3_insttype_excluded'
        WHEN R.fileDate IS NULL                        THEN '4_filedate_null'
        WHEN el.leaseID IS NULL                        THEN '5_no_exportlog_leaseid'
        WHEN mcl.leasingID IS NULL                     THEN '6_county_not_mapped'
        WHEN TRY_CONVERT(BIGINT, CONVERT(VARCHAR(50), el.leaseID)) IS NULL
                                                       THEN '7_leaseid_not_numeric'
        WHEN (R.[_ModifiedDateTime]  < dl.LastProcessedDateLandLeaseProducer
          AND el.[_ModifiedDateTime] < dl.LastProcessedDateLandLeaseProducer)
                                                       THEN '8_behind_watermark_orphaned'
        ELSE '9_passes_all_hard_gates'
    END                                                                AS first_failed_gate
FROM #affected a
LEFT JOIN [dbo].[tblrecord]          R  ON R.recordID = a.recordID
LEFT JOIN [dbo].[tblLookupCounties]  C  ON C.countyID = R.countyID
LEFT JOIN [dbo].[tblDataLoadersPerCounty] dl ON dl.CountyID = R.countyID
OUTER APPLY (SELECT TOP 1 leaseID, [_ModifiedDateTime]
             FROM [dbo].[tblexportLog]
             WHERE recordID = R.recordID AND LeaseID IS NOT NULL
             ORDER BY [_ModifiedDateTime] DESC, exportLogID DESC) el
OUTER APPLY (SELECT TOP 1 mcl.leasingID
             FROM [Tracker].[MasterCountyLookup] mcl
             WHERE mcl.leasingID = C.Div1CountyID) mcl
OUTER APPLY (SELECT COUNT(*) AS land_desc_count
             FROM [dbo].[tbllandDescription] L
             WHERE L.recordID = R.recordID AND L.IsDeleted = 0) ld
ORDER BY a.county, a.recordID;

/* ---------- headline rollup: how many records fail at each gate ---------- */
SELECT first_failed_gate, COUNT(*) AS records
FROM (
    SELECT
    CASE
        WHEN R.recordID IS NULL                       THEN '1_record_not_found'
        WHEN R.StatusID NOT IN (4,10,16)              THEN '2_status_excluded'
        WHEN R.instrumentTypeID IN ('ASN','MD')       THEN '3_insttype_excluded'
        WHEN R.fileDate IS NULL                        THEN '4_filedate_null'
        WHEN el.leaseID IS NULL                        THEN '5_no_exportlog_leaseid'
        WHEN mcl.leasingID IS NULL                     THEN '6_county_not_mapped'
        WHEN TRY_CONVERT(BIGINT, CONVERT(VARCHAR(50), el.leaseID)) IS NULL
                                                       THEN '7_leaseid_not_numeric'
        WHEN (R.[_ModifiedDateTime]  < dl.LastProcessedDateLandLeaseProducer
          AND el.[_ModifiedDateTime] < dl.LastProcessedDateLandLeaseProducer)
                                                       THEN '8_behind_watermark_orphaned'
        ELSE '9_passes_all_hard_gates'
    END AS first_failed_gate
    FROM #affected a
    LEFT JOIN [dbo].[tblrecord]          R  ON R.recordID = a.recordID
    LEFT JOIN [dbo].[tblLookupCounties]  C  ON C.countyID = R.countyID
    LEFT JOIN [dbo].[tblDataLoadersPerCounty] dl ON dl.CountyID = R.countyID
    OUTER APPLY (SELECT TOP 1 leaseID, [_ModifiedDateTime] FROM [dbo].[tblexportLog]
                 WHERE recordID = R.recordID AND LeaseID IS NOT NULL
                 ORDER BY [_ModifiedDateTime] DESC, exportLogID DESC) el
    OUTER APPLY (SELECT TOP 1 mcl.leasingID FROM [Tracker].[MasterCountyLookup] mcl
                 WHERE mcl.leasingID = C.Div1CountyID) mcl
) t
GROUP BY first_failed_gate
ORDER BY first_failed_gate;
