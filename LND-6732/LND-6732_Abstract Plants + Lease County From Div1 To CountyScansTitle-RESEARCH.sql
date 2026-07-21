-- Work with Claude to find cases where a typo in the recordnumber would break the match (Potential Missed Matches)

/*
==============================================================================
README: CountyScansTitle and DIV1 Record Matching System
==============================================================================
Last Updated: 2025-03-17 16:01:22 UTC
Author: donald-massey

OVERVIEW:
This comprehensive SQL script establishes a system to identify and match lease 
records between two databases: CountyScansTitle and DIV1. It focuses on oil and 
gas leases across specific Texas and New Mexico counties.

MATCHING CONDITIONS:
- Record Number Match: Exact match on record numbers and dates
- Volume to Record Number Match: CST volume matches DIV1 record number
- Partial String Match: Record numbers contain each other as substrings
- DIV1 Only - No CST Match: DIV1 leases without corresponding CST records

USAGE:
- Run complete script to create temporary tables and generate matches
- Filter results by match_condition to prioritize different types of matches
- Use analytics sections to compare record volumes across systems

COMPONENTS:
1. Temporary Tables Creation
   - #LND_6732_modded_cst_values: Normalized CountyScansTitle records
   - #LND_6732_modded_div1_values: Normalized DIV1 records
   
2. Data Transformation
   - Standardized numeric record identifiers
   - Consistent date formats
   - Cleaned volume and page numbers
   
3. Analytics Queries
   - Record count comparisons by county and time period
   - Historical plant and lease analytics

PERFORMANCE NOTES:
- Optimized with UNION ALL over OR conditions for better index utilization
- Includes appropriate indexes on temporary tables
- Additional analytical queries for verification and troubleshooting
==============================================================================
*/



/* CountyScansTitle Temporary Table Documentation:
   This query extracts and transforms record data into a temporary table #LND_6732_modded_cst_values with the following column modifications:

Values Gathered:
	• Records filtered for Texas (stateID = 48) with specific counties or New Mexico (stateID = 35) county Eddy
	• Only records where LeaseID is NULL in the export log (not previously exported)
	• Only oil and gas lease related instruments (MOGL, OGL, OGLAMD, POGL, OGLEXT, ROGL)
	• Only records with statusIDs: 4, 10, 16, 18 (representing specific record statuses)

• recordID
  - Direct selection of the unique record identifier from tblrecord
  - No transformation applied
• recordNumber
  - Direct selection of the original record number as stored in the database
  - No transformation applied
• bigint_recordNumber
  - Extracts only numeric portions from recordNumber
  - Uses TRANSLATE and REPLACE to remove all alphabetic characters and hyphens
  - Converts result to BIGINT data type
  - Returns NULL if resulting numeric value equals 0
  - Purpose: Standardizes numeric record identifiers for sorting and indexing
• nvarchar_recordNumber
  - Extracts only numeric portions from recordNumber
  - Uses TRANSLATE and REPLACE to remove all alphabetic characters and hyphens
  - Preserves as NVARCHAR data type
  - Purpose: Allows string operations on cleaned numeric portions
• fileDate
  - Converts original fileDate to yyyy-mm-dd format string (varchar)
  - Purpose: Standardizes date format for consistency
• volume
  - Attempts to convert volume field to INTEGER
  - Returns NULL for empty strings or non-numeric values
  - Returns NULL if numeric value equals 0
  - Purpose: Creates clean numeric volume values for sorting/filtering
• page
  - Attempts to convert page field to INTEGER
  - Returns NULL for empty strings or non-numeric values
  - Returns NULL if numeric value equals 0
  - Purpose: Creates clean numeric page values for sorting/filtering
• countyID
  - Direct selection of county identifier from tblrecord
  - No transformation applied */


-- Check if temporary table exists and drop it if it does
IF OBJECT_ID('tempdb..#LND_6732_cst_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_cst_values;

-- Create temporary table with unsanitized data
SELECT tr.recordID as recordID
      ,recordNumber AS recordNumber
	  ,CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.volume,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.volume,''))
	   END AS volume
	  ,CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.page,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.page,''))
	   END AS page
      ,CONVERT(varchar, tr.fileDate, 23) AS fileDate
      ,tr.countyID
      ,tlc.CountyName
INTO #LND_6732_cst_values
FROM countyScansTitle.dbo.tblrecord tr
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tr.recordID = tel.recordID
LEFT JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tr.countyID = tlc.countyID
WHERE (tr.stateID = 48 
   AND tr.countyID IN (2,26,52,53,64,87,93,113,114,118,145,151,154,156,165,186,192,195,198,231,236,238,248)
    OR tr.stateID = 35 AND tr.countyID IN (263))
  AND tr.InstrumentTypeID IN ('MOGL','OGL','OGLAMD','POGL','OGLEXT','ROGL')
  AND statusID IN (4,10,16,18);


/*
-- Check if temporary table exists and drop it if it does
IF OBJECT_ID('tempdb..#LND_6732_modded_cst_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_modded_cst_values;

-- Create temporary table with data
SELECT tr.recordID as recordID
      ,recordNumber AS recordNumber
      ,CASE
			WHEN TRY_CONVERT(BIGINT, REPLACE(TRANSLATE(tr.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ','')) = 0
			THEN NULL
			ELSE TRY_CONVERT(BIGINT, REPLACE(TRANSLATE(tr.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ',''))
	   END AS bigint_recordNumber
	  ,TRY_CONVERT(NVARCHAR, REPLACE(TRANSLATE(tr.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ','')) as nvarchar_recordNumber
      ,CONVERT(varchar, tr.fileDate, 23) AS fileDate
	  ,CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.volume,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.volume,''))
	   END AS volume
	  ,CASE
			WHEN TRY_CONVERT(INT, ISNULL(tr.page,'')) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, ISNULL(tr.page,''))
	   END AS page
	  ,tr.countyID
	  ,tlc.CountyName
INTO #LND_6732_modded_cst_values
FROM countyScansTitle.dbo.tblrecord tr
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tr.recordID = tel.recordID
LEFT JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tr.countyID = tlc.countyID
WHERE (tr.stateID = 48 
   AND tr.countyID IN (2,26,52,53,64,87,93,113,114,118,145,151,154,156,165,186,192,195,198,231,236,238,248)
    OR tr.stateID = 35 AND tr.countyID IN (263))
  AND tr.InstrumentTypeID IN ('MOGL','OGL','OGLAMD','POGL','OGLEXT','ROGL')
  AND statusID IN (4,10,16,18);

-- Primary clustered index on recordID (assuming it's unique)
CREATE CLUSTERED INDEX IX_LND_6732_recordID ON #LND_6732_modded_cst_values (recordID);
-- Non-clustered indexes for common filtering/joining columns
CREATE NONCLUSTERED INDEX IX_LND_6732_countyID ON #LND_6732_modded_cst_values (countyID);
CREATE NONCLUSTERED INDEX IX_LND_6732_fileDate ON #LND_6732_modded_cst_values (fileDate);
CREATE NONCLUSTERED INDEX IX_LND_6732_recordNumber ON #LND_6732_modded_cst_values (recordNumber);
-- Composite index for volume+page lookups (common for document references)
CREATE NONCLUSTERED INDEX IX_LND_6732_volume_page ON #LND_6732_modded_cst_values (volume, page);
-- Index for the transformed bigint version of record number
CREATE NONCLUSTERED INDEX IX_LND_6732_bigint_recordNumber ON #LND_6732_modded_cst_values (bigint_recordNumber);
-- Index for the transformed nvarchar version of record number
CREATE NONCLUSTERED INDEX IX_LND_6732_nvarchar_recordNumber ON #LND_6732_modded_cst_values (nvarchar_recordNumber);
*/


/* DIV1 Temporary Table Documentation:
	This query extracts and transforms record data into temporary table #LND_6732_modded_div1_values with the following column modifications:

• LeaseID
  - Direct selection of the lease identifier from tblLegalLease
  - No transformation applied
• recordNumber
  - Direct selection of the original record number as stored in the database
  - No transformation applied
• bigint_recordNumber
  - Extracts only numeric portions from recordNumber
  - Uses TRANSLATE and REPLACE to remove all alphabetic characters and hyphens
  - Converts result to BIGINT data type
  - Returns NULL if resulting numeric value equals 0
  - Purpose: Standardizes numeric record identifiers for sorting and indexing
• nvarchar_recordNumber
  - Extracts only numeric portions from recordNumber
  - Uses TRANSLATE and REPLACE to remove all alphabetic characters and hyphens
  - Preserves as NVARCHAR data type
  - Purpose: Allows string operations on cleaned numeric portions
• RecordDate
  - Converts original RecordDate to yyyy-mm-dd format string (varchar)
  - Purpose: Standardizes date format for consistency
• volume
  - Attempts to convert Vol field to INTEGER
  - Returns NULL if numeric value equals 0
  - Purpose: Creates clean numeric volume values for sorting/filtering
• page
  - Attempts to convert pg field to INTEGER
  - Returns NULL if numeric value equals 0
  - Purpose: Creates clean numeric page values for sorting/filtering

Values Gathered:
	• Records filtered for specific counties (24 total) including:
	  - 23 counties from Texas (including Andrews, Burleson, Reagan, Reeves, etc.)
	  - 1 county from New Mexico (Eddy, NM - CountyID 408)
	• Data is sourced from the Div 1 database (AUS2-DIV1-DDB01.div1_daily)
	• No additional filtering criteria applied beyond county selection */


-- Check if temporary table exists and drop it if it does
IF OBJECT_ID('tempdb..#LND_6732_div1_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_div1_values;

-- Create temporary table with raw, unsanitized data
SELECT LeaseID
      ,recordNumber
      ,CONVERT(varchar, RecordDate, 23) as RecordDate
	  ,CASE
			WHEN TRY_CONVERT(INT, tll.Vol) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, tll.Vol)
	   END AS volume
	  ,CASE
			WHEN TRY_CONVERT(INT,tll.pg) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT,tll.pg)
	   END AS page
      ,tc.CountyName
INTO #LND_6732_div1_values
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblCounty] tc ON tc.CountyID = tll.CountyID
WHERE tll.CountyID IN (2,26,52,53,64,86,91,111,112,116,143,149,152,154,163,184,190,193,196,229,234,236,246,408);

/*
-- Check if temporary table exists and drop it if it does
IF OBJECT_ID('tempdb..#LND_6732_modded_div1_values', 'U') IS NOT NULL
    DROP TABLE #LND_6732_modded_div1_values;

-- Create temporary table with data
SELECT LeaseID
      ,recordNumber
      ,CASE
			WHEN TRY_CONVERT(BIGINT, REPLACE(TRANSLATE(tll.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ','')) = 0
			THEN NULL
			ELSE TRY_CONVERT(BIGINT, REPLACE(TRANSLATE(tll.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ',''))
	   END AS bigint_recordNumber
      ,TRY_CONVERT(NVARCHAR, REPLACE(TRANSLATE(tll.RecordNumber, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-','                                                     '),' ','')) as nvarchar_recordNumber
	  ,CONVERT(varchar, tll.RecordDate, 23) AS RecordDate
	  ,CASE
			WHEN TRY_CONVERT(INT, tll.Vol) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT, tll.Vol)
	   END AS volume
	  ,CASE
			WHEN TRY_CONVERT(INT,tll.pg) = 0
			THEN NULL
			ELSE TRY_CONVERT(INT,tll.pg)
	   END AS page
	  ,tc.CountyName
INTO #LND_6732_modded_div1_values
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblCounty] tc ON tc.CountyID = tll.CountyID
WHERE tll.CountyID IN (2,26,52,53,64,86,91,111,112,116,143,149,152,154,163,184,190,193,196,229,234,236,246,408);
*/
-- End Temporary Table Creation



/*  This query joins county scan title and DIV 1 records based on matching criteria, selecting the following columns:

• cst_recordID
  - Record identifier from county scans title system
  - Sources from #LND_6732_modded_cst_values.recordID
  - No transformation applied
• cst_recordno
  - Standardized numeric record number from county scans title
  - Sources from #LND_6732_modded_cst_values.bigint_recordNumber
  - Already cleaned and converted to BIGINT in source table
• div1_leaseid
  - Lease identifier from DIV1 system
  - Sources from #LND_6732_modded_div1_values.LeaseID
  - No transformation applied
• div1_recordno
  - Standardized numeric record number from DIV1 system
  - Sources from #LND_6732_modded_div1_values.bigint_recordNumber
  - Already cleaned and converted to BIGINT in source table
• cst_volume
  - Volume number from county scans title system
  - Sources from #LND_6732_modded_cst_values.volume
  - Already cleaned and converted to INTEGER in source table
• cst_page
  - Page number from county scans title system
  - Sources from #LND_6732_modded_cst_values.page
  - Already cleaned and converted to INTEGER in source table
• div1_volume
  - Volume number from DIV1 system
  - Sources from #LND_6732_modded_div1_values.volume
  - Already cleaned and converted to INTEGER in source table
• div1_page
  - Page number from DIV1 system
  - Sources from #LND_6732_modded_div1_values.page
  - Already cleaned and converted to INTEGER in source table
• cst_countyID
  - County identifier from county scans title system
  - Sources from #LND_6732_modded_cst_values.countyID
  - No transformation applied

Values Gathered:
	• Records are matched between two systems using multiple join conditions:
	  - Primary match: Record numbers and dates match exactly (~32,061 records)
	  - Secondary match: CST volume matches DIV1 record number with matching dates (~280 records)
	  - Tertiary match: Record numbers have different lengths but contain each other as substrings
		with matching dates (~545 records), limited to numbers at least 5 digits long
	• A LEFT JOIN to tblexportLog ensures that export information is included when available
	• Combines data from county scans title system with DIV1 system for comparison/verification
	• Intended to find corresponding records across different database systems

Performance Optimizations (Added 2025-03-14):
	• Replaced multiple OR conditions with UNION ALL operations to enable better index utilization
	  - Each join condition now executes separately, allowing the optimizer to choose appropriate execution plans
	  - Maintains the same result set while improving performance
	• Recommended indexes on temporary tables to support efficient joins:
	  - IX_cst_bigint_recordNumber_fileDate on #LND_6732_modded_cst_values (bigint_recordNumber, fileDate)
	  - IX_cst_volume_fileDate on #LND_6732_modded_cst_values (volume, fileDate)
	  - IX_cst_recordID on #LND_6732_modded_cst_values (recordID)
	  - IX_div1_bigint_recordNumber_RecordDate on #LND_6732_modded_div1_values (bigint_recordNumber, RecordDate)
	  - IX_div1_LeaseID on #LND_6732_modded_div1_values (LeaseID)
	• Alternative filtering approach using EXISTS instead of LEFT JOIN for potentially better performance
	• Additional optimization techniques:
	  - Consider using query hints like RECOMPILE for optimal plan generation
	  - Pre-filter data before joining where possible
	  - Update statistics on temporary tables to improve cardinality estimates
*/

-- Match on Unsanitized Temp Tables
-- First Condition: Matches recordNumber, recordDate, countyName & tblExportlog LeaseID IS NULL Records: 12,323
SELECT 
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName
FROM #LND_6732_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON tel.LeaseID = div1.LeaseID
LEFT JOIN #LND_6732_cst_values cst
    ON cst.recordNumber = div1.recordNumber 
    AND cst.fileDate = div1.RecordDate
    AND cst.countyName = div1.CountyName
WHERE tel.leaseID IS NULL

UNION  -- Records: 17,479

-- Second Condition: Matches Vol/Page, recordDate, countyName & tblExportLog LeaseID IS NULL Records: 4,855
SELECT 
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName
FROM #LND_6732_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON tel.LeaseID = div1.LeaseID
LEFT JOIN #LND_6732_cst_values cst
     ON cst.fileDate = div1.RecordDate
    AND cst.countyName = div1.CountyName
    AND cst.volume = div1.volume 
    AND cst.page = div1.page
WHERE tel.leaseID IS NULL
AND cst.recordNumber <> div1.recordNumber

UNION

-- Verify this is a one-to-one match and check with Lindsey if this should be included
/*
-- Third condition: partial string matching with length checks: 3,104 records
SELECT 
    -- CST (County Scan Title) record identifiers
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    
    -- Division 1 record identifiers
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    
    -- Volume and page numbers from both sources for verification
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    
    -- County information
    div1.CountyName AS div1_countyName
FROM 
    -- Start with div1 as the primary table (with subquery for match counting)
    (
        SELECT 
            div1.*,
            -- Count potential matches for each unique combination of date, county and record number
            COUNT(*) OVER (
                PARTITION BY div1.RecordDate, div1.CountyName, div1.recordNumber
            ) AS match_count
        FROM 
            #LND_6732_div1_values div1
    ) div1
-- Check export log first to filter for unprocessed leases
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON tel.LeaseID = div1.LeaseID
-- Then join to CST with the string matching logic
LEFT JOIN #LND_6732_cst_values cst
    ON LEN(cst.recordNumber) <> LEN(div1.recordNumber)  -- Different record number lengths
    AND LEN(cst.recordNumber) >= 5                      -- CST record number must be ≥ 5 chars
    AND LEN(div1.recordNumber) >= 5                     -- DIV1 record number must be ≥ 5 chars
    AND cst.fileDate = div1.RecordDate                  -- Dates must match
    AND cst.countyName = div1.countyName                -- Counties must match
    AND (
        -- One record number must be a substring of the other
        CHARINDEX(cst.recordNumber, div1.recordNumber) > 0 
        OR CHARINDEX(div1.recordNumber, cst.recordNumber) > 0
    )
WHERE 
    tel.LeaseID IS NULL      -- Only leases not in the export log
    AND div1.match_count = 1  -- Critical condition: ensure there's exactly one match in div1
    AND cst.recordID IS NOT NULL  -- Only include records that have a potential match in CST
*/


/*
-- match on sanitized temp tables: 12,327 records
SELECT 
    cst.recordID AS cst_recordID,
    cst.bigint_recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.bigint_recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName
FROM #LND_6732_modded_div1_values div1
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON tel.LeaseID = div1.LeaseID
LEFT JOIN #LND_6732_modded_cst_values cst
    ON cst.bigint_recordNumber = div1.bigint_recordNumber 
    AND cst.fileDate = div1.RecordDate
    AND cst.countyName = div1.CountyName
WHERE tel.leaseID IS NULL

UNION ALL

-- Second condition: partial string matching with length checks: 12,166 records
SELECT 
    -- CST (County Scan Title) record identifiers
    cst.recordID AS cst_recordID,
    cst.bigint_recordNumber AS cst_recordno,
    
    -- Division 1 record identifiers
    div1.LeaseID AS div1_leaseid,
    div1.bigint_recordNumber AS div1_recordno,
    
    -- Volume and page numbers from both sources for verification
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    
    -- County information
    div1.CountyName AS div1_countyName
FROM 
    -- Subquery to calculate match counts to ensure unique matches only
    (
        SELECT 
            div1.*,
            -- Count potential matches for each unique combination of date, county and record number
            COUNT(*) OVER (
                PARTITION BY div1.RecordDate, div1.CountyName, div1.bigint_recordNumber
            ) AS match_count
        FROM 
            #LND_6732_modded_div1_values div1
    ) div1
-- Check export log to exclude already processed records
LEFT JOIN 
    countyScansTitle.dbo.tblexportLog tel ON tel.LeaseID = div1.LeaseID
LEFT JOIN 
    #LND_6732_modded_cst_values cst
    -- Join conditions ensure appropriate matching logic
    ON LEN(cst.bigint_recordNumber) <> LEN(div1.bigint_recordNumber)  -- Different record number lengths
    AND LEN(cst.bigint_recordNumber) >= 5                             -- CST record number must be ≥ 5 chars
    AND LEN(div1.bigint_recordNumber) >= 5                            -- DIV1 record number must be ≥ 5 chars
    AND cst.fileDate = div1.RecordDate                                -- Dates must match
    AND cst.countyName = div1.countyName                              -- Counties must match
    AND (
        -- One record number must be a substring of the other
        CHARINDEX(cst.nvarchar_recordNumber, div1.nvarchar_recordNumber) > 0 
        OR CHARINDEX(div1.nvarchar_recordNumber, cst.nvarchar_recordNumber) > 0
    )
    AND div1.match_count = 1  -- Critical condition: ensure there's exactly one match in div1
WHERE 
    tel.leaseID IS NULL;  -- Only include records that haven't been exported yet
*/

/*
==============================================================================
QUERY: All Potential CST-DIV1 Matches Not Yet in tblexportLog + DIV1 Only Records
==============================================================================
Updated by: donald-massey
Updated on: 2025-03-18 17:45:50 UTC

PURPOSE:
This query identifies all potential matches between CountyScanTitle and DIV1 
records that have not yet been logged in tblexportLog, plus DIV1 records
that don't exist in countyScansTitle at all.

EXPLANATION:
- The query returns the same data as the original query plus DIV1-only records
- Each row represents either a potential match or a DIV1-only record
- The match_condition column shows which condition was used (including the new DIV1-only condition)
- Only shows CST records that don't have entries in tblexportLog
==============================================================================
*/

-- First condition: record number matching
SELECT 
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName,
    'Record Number Match' AS match_condition
FROM #LND_6732_cst_values cst
JOIN #LND_6732_div1_values div1 
    ON cst.recordNumber = div1.recordNumber 
    AND cst.fileDate = div1.RecordDate
    AND cst.countyName = div1.CountyName
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON cst.recordID = tel.recordID
WHERE tel.leaseID IS NULL

UNION ALL

-- Second condition: recordNumber IS NULL, cst.volume = div1.volume & cst.page = div1.page
SELECT 
    cst.recordID AS cst_recordID,
    cst.recordNumber AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    cst.volume AS cst_volume,
    cst.page AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName,
    'Partial String Match' AS match_condition
FROM 
    -- Add match counting for DIV1 records
    (
        SELECT 
            div1.*,
            -- Count potential matches for each unique combination of date, county and record number
            COUNT(*) OVER (
                PARTITION BY div1.RecordDate, div1.CountyName, div1.recordNumber
            ) AS match_count
        FROM 
            #LND_6732_unsanitized_div1_values div1
    ) div1
JOIN #LND_6732_unsanitized_cst_values cst
    ON LEN(cst.recordNumber) <> LEN(div1.recordNumber)
    AND LEN(cst.recordNumber) >= 5 
    AND LEN(div1.recordNumber) >= 5
    AND cst.fileDate = div1.RecordDate
    AND cst.countyName = div1.CountyName
    AND (
        CHARINDEX(cst.recordNumber, div1.recordNumber) > 0 
        OR CHARINDEX(div1.recordNumber, cst.recordNumber) > 0
    )
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON cst.recordID = tel.recordID
WHERE tel.leaseID IS NULL
    AND div1.match_count = 1  -- Ensure there's exactly one match

UNION ALL

-- Third condition: DIV1 leases that don't exist in countyScansTitle at all
SELECT 
    NULL AS cst_recordID,
    NULL AS cst_recordno,
    div1.LeaseID AS div1_leaseid,
    div1.recordNumber AS div1_recordno,
    NULL AS cst_volume,
    NULL AS cst_page,
    div1.volume AS div1_volume,
    div1.page AS div1_page,
    div1.CountyName AS div1_countyName,
    'DIV1 Only - No CST Match' AS match_condition
FROM #LND_6732_unsanitized_div1_values div1
LEFT JOIN #LND_6732_unsanitized_cst_values cst1 
    ON div1.recordNumber = cst1.recordNumber 
    AND div1.RecordDate = cst1.fileDate
    AND div1.CountyName = cst1.countyName
LEFT JOIN #LND_6732_unsanitized_cst_values cst3
    ON (LEN(cst3.recordNumber) <> LEN(div1.recordNumber)
        AND LEN(cst3.recordNumber) >= 5 
        AND LEN(div1.recordNumber) >= 5
        AND cst3.fileDate = div1.RecordDate
        AND cst3.countyName = div1.CountyName
        AND (
            CHARINDEX(cst3.recordNumber, div1.recordNumber) > 0 
            OR CHARINDEX(div1.recordNumber, cst3.recordNumber) > 0
        )
    )
LEFT JOIN countyScansTitle.dbo.tblexportLog tel 
    ON tel.leaseID = div1.LeaseID
WHERE cst1.recordID IS NULL 
  AND cst3.recordID IS NULL
  AND tel.leaseID IS NULL

ORDER BY cst_recordID, div1_leaseid;


/* -- Backup of base query
SELECT cst.recordID AS cst_recordID
      ,cst.bigint_recordNumber AS cst_recordno
	  ,div1.LeaseID AS div1_leaseid
	  ,div1.bigint_recordNumber AS div1_recordno
	  ,cst.volume AS cst_volume
	  ,cst.page AS cst_page
	  ,div1.volume AS div1_volume
	  ,div1.page AS div1_page
	  ,cst.countyID AS cst_countyID
FROM #LND_6732_modded_cst_values cst
JOIN #LND_6732_modded_div1_values div1 ON 
-- Check the counts + values against the old queries
(
	(cst.bigint_recordNumber = div1.bigint_recordNumber AND cst.fileDate = div1.RecordDate)  --32,061 records
		OR (cst.volume = div1.bigint_recordNumber AND cst.fileDate = div1.RecordDate)  --280 records
		OR (LEN(cst.bigint_recordNumber) <> LEN(div1.bigint_recordNumber)
		    AND LEN(cst.bigint_recordNumber) >= 5 AND LEN(div1.bigint_recordNumber) >= 5
			AND (CHARINDEX(cst.nvarchar_recordNumber, div1.nvarchar_recordNumber) > 0 AND cst.fileDate = div1.RecordDate
			OR CHARINDEX(div1.nvarchar_recordNumber, cst.nvarchar_recordNumber) > 0 AND cst.fileDate = div1.RecordDate))  --545 records
)
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON cst.recordID = tel.recordID
WHERE tel.leaseID IS NULL;
*/


-- The answer to Lindseys question is, I had my joins reversed >_<
SELECT l.leaseID, el.*
FROM [aus2-div1-ddb01].[div1_daily].[dbo].tbllegallease l
JOIN [aus2-div1-ddb01].[div1_daily].[dbo].tblcounty tc 
	ON l.countyid = tc.countyid
LEFT JOIN countyScansTitle.dbo.tblexportLog el 
	ON el.LeaseID = l.leaseid
WHERE tc.CountyID IN (2, 26, 52, 53, 64, 86, 91, 111, 112, 116, 143, 149, 152, 154, 163, 184, 190, 193, 196, 229, 234, 236, 246, 408)
and el.leaseid IS NULL
--AND el.recordid IS NULL 


-- Abstract Plant + Lease (Houston, Reeves, Eddy)
SELECT 
    tlc.CountyName,
    DATEPART(YEAR, tr._CreatedDateTime) AS year,
    DATEPART(MONTH, tr._CreatedDateTime) AS month,
    COUNT(*) AS record_count
FROM countyScansTitle.dbo.tblrecord tr
LEFT JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tr.countyID = tlc.countyID
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tr.recordID = tel.recordID
WHERE tr.recordIsLease = 1 and tlc.CountyName IN ('Houston','Reeves','Eddy')
GROUP BY 
    tlc.CountyName, 
    DATEPART(YEAR, tr._CreatedDateTime), 
    DATEPART(MONTH, tr._CreatedDateTime)
ORDER BY 
    tlc.CountyName, 
    year, 
    month;

SELECT 
    tc.CountyName,
    DATEPART(YEAR, tll.created) AS year,
    DATEPART(MONTH, tll.created) AS month,
    COUNT(*) AS record_count
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblCounty] tc ON tll.CountyID = tc.CountyID
WHERE tc.CountyName IN ('Houston','Reeves','Eddy')
GROUP BY 
    tc.CountyName, 
    DATEPART(YEAR, tll.created), 
    DATEPART(MONTH, tll.created)
ORDER BY 
    tc.CountyName, 
    year, 
    month;


-- Historical Plant + Lease (Jack, ,LaSalle, Montague)
SELECT 
    tlc.CountyName,
    DATEPART(YEAR, tr._CreatedDateTime) AS year,
    DATEPART(MONTH, tr._CreatedDateTime) AS month,
    COUNT(*) AS record_count
FROM countyScansTitle.dbo.tblrecord tr
LEFT JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tr.countyID = tlc.countyID
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tr.recordID = tel.recordID
WHERE tr.recordIsLease = 1 and tlc.CountyName IN ('Jack','LaSalle','Montague')
GROUP BY 
    tlc.CountyName, 
    DATEPART(YEAR, tr._CreatedDateTime), 
    DATEPART(MONTH, tr._CreatedDateTime)
ORDER BY 
    tlc.CountyName, 
    year, 
    month;

SELECT 
    tc.CountyName,
    DATEPART(YEAR, tll.created) AS year,
    DATEPART(MONTH, tll.created) AS month,
    COUNT(*) AS record_count
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblCounty] tc ON tll.CountyID = tc.CountyID
WHERE tc.CountyName IN ('Jack','LaSalle','Montague')
GROUP BY 
    tc.CountyName, 
    DATEPART(YEAR, tll.created), 
    DATEPART(MONTH, tll.created)
ORDER BY 
    tc.CountyName, 
    year, 
    month;


-- Non-Historical Plant + Lease (Washington, Harrison, Marion)
SELECT 
    tlc.CountyName,
    DATEPART(YEAR, tr._CreatedDateTime) AS year,
    DATEPART(MONTH, tr._CreatedDateTime) AS month,
    COUNT(*) AS record_count
FROM countyScansTitle.dbo.tblrecord tr
LEFT JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tr.countyID = tlc.countyID
LEFT JOIN countyScansTitle.dbo.tblexportLog tel ON tr.recordID = tel.recordID
WHERE tr.recordIsLease = 1 and tlc.CountyName IN ('Washington', 'Harrison', 'Marion')
GROUP BY 
    tlc.CountyName, 
    DATEPART(YEAR, tr._CreatedDateTime), 
    DATEPART(MONTH, tr._CreatedDateTime)
ORDER BY 
    tlc.CountyName, 
    year, 
    month;

SELECT 
    tc.CountyName,
    DATEPART(YEAR, tll.created) AS year,
    DATEPART(MONTH, tll.created) AS month,
    COUNT(*) AS record_count
FROM [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblLegalLease] tll
LEFT JOIN [AUS2-DIV1-DDB01].[div1_daily].[dbo].[tblCounty] tc ON tll.CountyID = tc.CountyID
WHERE tc.CountyName IN ('Washington', 'Harrison', 'Marion')
GROUP BY 
    tc.CountyName, 
    DATEPART(YEAR, tll.created), 
    DATEPART(MONTH, tll.created)
ORDER BY 
    tc.CountyName, 
    year, 
    month;