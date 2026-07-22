-- SUPERSEDED by diagnose_missing9_rootcause.sql. This checked only CSTitle
-- tbllandDescription, but the legal_lease per-tract docs are keyed by the Div1 mapping_id
-- (tblleaseAbstractMapping.mappingid), not CSTitle land descriptions. Use the rootcause file.
--
-- The 9 group-3 leases missing from legal_lease. The index is one doc per
-- land-description/tract (cstitle_get_land_descriptions: INNER JOIN tbllandDescription,
-- IsDeleted=0). A record with zero non-deleted land descriptions yields no tract doc.
-- Compare land-description coverage of the 9 missing vs the 17 present. Run from CSTitle.

SELECT
    r.recordID,
    r.recordNumber,
    c.countyName,
    r.instrumentTypeID,
    COUNT(ld.landDescriptionID)                                              AS total_land_desc,
    SUM(CASE WHEN ld.IsDeleted = 0 THEN 1 ELSE 0 END)                        AS active_land_desc,
    SUM(CASE WHEN ld.IsDeleted = 1 THEN 1 ELSE 0 END)                        AS deleted_land_desc
FROM countyScansTitle.dbo.tblrecord r
JOIN countyScansTitle.dbo.tbllookupCounties c ON c.countyID = r.countyID
LEFT JOIN countyScansTitle.dbo.tbllandDescription ld ON ld.recordID = r.recordID
WHERE r.recordID IN (
    'f98d1a0d-f424-4c8c-8e78-8940fc64ef3a',  -- 4989831 Guadalupe  (MISSING)
    '7d321a52-931a-4040-9ace-f084d06babf4',  -- 4547892 McMullen   (MISSING)
    '3bfc2172-d7df-43d8-8b45-efb24d689a6c',  -- 4547893 McMullen   (MISSING)
    '1218f1e7-4a3e-4b5b-aa88-7dbebdb2dab2',  -- 4547894 McMullen   (MISSING)
    '80db494e-e73b-4c6c-81ba-741a9d890685',  -- 4547895 McMullen   (MISSING)
    '1b8d765f-0d20-4a58-9ada-48b8f80fd1df',  -- 4547896 McMullen   (MISSING)
    '064e5d99-8bfe-4157-a1c5-3724c2370b85',  -- 4547897 McMullen   (MISSING)
    '9dcd0169-ce07-410b-aa25-0d46e22f7cd8',  -- 4547898 McMullen   (MISSING)
    '66d99bf5-949e-4f25-9655-cb41beb55092',  -- 4233079 McMullen   (MISSING)
    -- present, for contrast:
    '995fc18f-f9ed-4ddb-a8f7-28a193867820',  -- 4238366 McMullen   (PRESENT, 26 docs)
    'c723fc9a-2d40-45e0-8b72-006b9121ac87',  -- 4233745 McMullen   (PRESENT)
    'ea719dca-edf2-4e41-baca-a36f8e489698'   -- 4245391 McMullen   (PRESENT)
)
GROUP BY r.recordID, r.recordNumber, c.countyName, r.instrumentTypeID
ORDER BY active_land_desc, r.recordID;
