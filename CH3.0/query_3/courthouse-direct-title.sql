-- CHDT (courthouseDirectTitle) — CH3.0 county diagnostic
-- Same join pattern as query_1 but against the courthouseDirectTitle source.
-- Replace {COUNTY} with lowercase county name (e.g. 'cibola')
-- Output CSV (recordID in column 1) feeds query_cs_digital_from_chd_csv.py

SELECT *
FROM [courthouseDirectTitle].[dbo].[tblrecord] r
JOIN [courthouseDirectTitle].[dbo].[tbllookupcounties] c ON c.countyID = r.countyID
LEFT JOIN [courthouseDirectTitle].[cole].tblRecordProcessed p ON p.recordID = r.recordID
LEFT JOIN [courthouseDirectTitle].[dbo].[tblS3Image] s ON s.recordID = r.recordID
WHERE c.countyname = '{COUNTY}'
ORDER BY r.recordID