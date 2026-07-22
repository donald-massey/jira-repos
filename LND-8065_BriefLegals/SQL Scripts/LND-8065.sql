-- Ellis LandDescriptions llm-brief-legals-parser
SELECT
    l.LandDescriptionID,
	'Ellis' AS County,
	'TEXAS' AS State,
    l.BriefLegal
FROM [courthouseDirectTitle].[dbo].[tblRecord] r
JOIN [courthouseDirectTitle].[dbo].[tblLandDescription] l
    ON r.RecordID = l.recordID
WHERE r.CountyID = 71
  AND l.BriefLegal IS NOT NULL
  AND r.StatusID IN (4, 10, 16, 18)
  AND l.IsDeleted = 0

-- Ellis LandDescriptions brief-legals-parser
SELECT
    ld.LandDescriptionID,
	tlc.CountyName,
    tls.StateName,
	ld.BriefLegal
FROM [courthouseDirectTitle].[dbo].[tblRecord] tr
JOIN [courthouseDirectTitle].[dbo].[tblLandDescription] ld
    ON tr.RecordID = ld.recordID
JOIN [courthouseDirectTitle].[dbo].[tbllookupCounties] tlc
	ON tr.countyID = tlc.CountyID
JOIN [courthouseDirectTitle].[dbo].[tbllookupStates] tls
	ON tr.stateID = tls.StateID
WHERE tr.CountyID = 71
  AND ld.BriefLegal IS NOT NULL
  AND tr.StatusID IN (4, 10, 16, 18)
  AND ld.IsDeleted = 0

  -- Ellis LookupAbstractSurvey
SELECT [AbstractNumber]
      ,[SurveyName]
      ,[SurveySection]
      ,[SurveyBlock]
FROM [courthouseDirectTitle].[dbo].[LookupAbstractSurvey]
WHERE countyID = 71


-- Taylor LandDescriptions llm-brief-legals-parser
SELECT
    r.RecordID,
    r.CountyID,
    l.LandDescriptionID,
    l.BriefLegal,
    l.Subdivision,
    l.Lot,
    l.Block,
    l.AbstractName,
    l.AcreageByTract,
    l.QuarterCalls,
    r.Remarks
FROM [courthouseDirectTitle].[dbo].[tblRecord] r
JOIN [courthouseDirectTitle].[dbo].[tblLandDescription] l
    ON r.RecordID = l.recordID
WHERE r.CountyID = 221
  AND l.BriefLegal IS NOT NULL
  AND r.StatusID IN (4, 10, 16, 18)
  AND l.IsDeleted = 0

-- Taylor LandDescriptions brief-legals-parser
  SELECT
      ld.LandDescriptionID,
      ld.BriefLegal
  FROM [courthouseDirectTitle].[dbo].[tblRecord] tr
  JOIN [courthouseDirectTitle].[dbo].[tblLandDescription] ld
      ON tr.RecordID = ld.recordID
  JOIN [courthouseDirectTitle].[dbo].[tbllookupCounties] tlc
      ON tr.countyID = tlc.CountyID
  JOIN [courthouseDirectTitle].[dbo].[tbllookupStates] tls
      ON tr.stateID = tls.StateID
  WHERE tlc.countyName = 'Taylor'
    AND tls.StateName = 'Texas'
    AND ld.BriefLegal IS NOT NULL
    AND tr.StatusID IN (4, 10, 16, 18)
    AND ld.IsDeleted = 0


-- Taylor LookupAbstractSurvey
SELECT [AbstractNumber]
      ,[SurveyName]
      ,[SurveySection]
      ,[SurveyBlock]
FROM [courthouseDirectTitle].[dbo].[LookupAbstractSurvey]
WHERE countyID = 221


SELECT *
FROM courthouseDirectTitle.dbo.tbllookupCounties
WHERE countyName IN ('ellis','taylor')
and StateID = 48
-- Only process from CHDTitle
-- Review ELLIS (Non-Keyed)
--	Parse from 
-- Review Taylor (Keyed)


-- Taylor LLM brief-legals-parser statistics
  SELECT                                                                                                                                                                                                                                  COUNT(*) AS TotalRecords,
                                                                                                                                                                                                                                    
      -- Abstract                                                                 
      COUNT(Abstract) AS Abstract_Count,
      CAST(COUNT(Abstract) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Abstract_Pct,

      -- Survey
      COUNT(Survey) AS Survey_Count,
      CAST(COUNT(Survey) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Survey_Pct,

      -- Subdivision
      COUNT(Subdivision) AS Subdivision_Count,
      CAST(COUNT(Subdivision) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Subdivision_Pct,

      -- Lot
      COUNT(Lot) AS Lot_Count,
      CAST(COUNT(Lot) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Lot_Pct,

      -- Block
      COUNT(Block) AS Block_Count,
      CAST(COUNT(Block) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Block_Pct,

      -- Section
      COUNT(Section) AS Section_Count,
      CAST(COUNT(Section) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Section_Pct,

      -- Township
      COUNT(Township) AS Township_Count,
      CAST(COUNT(Township) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Township_Pct,

      -- Range
      COUNT(Range) AS Range_Count,
      CAST(COUNT(Range) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Range_Pct,

      -- QuarterCall
      COUNT(QuarterCall) AS QuarterCall_Count,
      CAST(COUNT(QuarterCall) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS QuarterCall_Pct,

      -- Acres
      COUNT(Acres) AS Acres_Count,
      CAST(COUNT(Acres) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Acres_Pct,

      -- NewCityBlock
      COUNT(NewCityBlock) AS NewCityBlock_Count,
      CAST(COUNT(NewCityBlock) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS NewCityBlock_Pct

  FROM [countyScansTitle].[dbo].[LND_8065_20260424_AI];



-- Taylor brief-legals-parser statistics
  SELECT                                                                                                                                                                                                                                  COUNT(*) AS TotalRecords,
                                                                                                                                                                                                                                    
      -- Abstract                                                                 
      COUNT(Abstract) AS Abstract_Count,
      CAST(COUNT(Abstract) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Abstract_Pct,

      -- Survey
      COUNT(Survey) AS Survey_Count,
      CAST(COUNT(Survey) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Survey_Pct,

      -- Subdivision
      COUNT(Subdivision) AS Subdivision_Count,
      CAST(COUNT(Subdivision) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Subdivision_Pct,

      -- Lot
      COUNT(Lot) AS Lot_Count,
      CAST(COUNT(Lot) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Lot_Pct,

      -- Block
      COUNT(Block) AS Block_Count,
      CAST(COUNT(Block) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Block_Pct,

      -- Section
      COUNT(Section) AS Section_Count,
      CAST(COUNT(Section) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Section_Pct,

      -- Township
      COUNT(Township) AS Township_Count,
      CAST(COUNT(Township) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Township_Pct,

      -- Range
      COUNT(Range) AS Range_Count,
      CAST(COUNT(Range) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Range_Pct,

      -- QuarterCall
      COUNT(QuarterCall) AS QuarterCall_Count,
      CAST(COUNT(QuarterCall) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS QuarterCall_Pct,

      -- Acres
      COUNT(Acres) AS Acres_Count,
      CAST(COUNT(Acres) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Acres_Pct,

      -- NewCityBlock
      COUNT(NewCityBlock) AS NewCityBlock_Count,
      CAST(COUNT(NewCityBlock) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS NewCityBlock_Pct

  FROM [countyScansTitle].[dbo].[LND_8065_20260424]
  WHERE countyName = 'taylor';



  -- Taylor brief-legals-parser statistics
  SELECT                                                                                                                                                                                                                                  COUNT(*) AS TotalRecords,
                                                                                                                                                                                                                                    
      -- Abstract                                                                 
      COUNT(Abstract) AS Abstract_Count,
      CAST(COUNT(Abstract) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Abstract_Pct,

      -- Survey
      COUNT(Survey) AS Survey_Count,
      CAST(COUNT(Survey) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Survey_Pct,

      -- Subdivision
      COUNT(Subdivision) AS Subdivision_Count,
      CAST(COUNT(Subdivision) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Subdivision_Pct,

      -- Lot
      COUNT(Lot) AS Lot_Count,
      CAST(COUNT(Lot) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Lot_Pct,

      -- Block
      COUNT(Block) AS Block_Count,
      CAST(COUNT(Block) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Block_Pct,

      -- Section
      COUNT(Section) AS Section_Count,
      CAST(COUNT(Section) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Section_Pct,

      -- Township
      COUNT(Township) AS Township_Count,
      CAST(COUNT(Township) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Township_Pct,

      -- Range
      COUNT(Range) AS Range_Count,
      CAST(COUNT(Range) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Range_Pct,

      -- QuarterCall
      COUNT(QuarterCall) AS QuarterCall_Count,
      CAST(COUNT(QuarterCall) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS QuarterCall_Pct,

      -- Acres
      COUNT(Acres) AS Acres_Count,
      CAST(COUNT(Acres) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS Acres_Pct,

      -- NewCityBlock
      COUNT(NewCityBlock) AS NewCityBlock_Count,
      CAST(COUNT(NewCityBlock) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS NewCityBlock_Pct

  FROM [countyScansTitle].[dbo].[LND_8065_20260424]
  WHERE countyName = 'ellis';



-- Test Data Extractor
DECLARE @county NVARCHAR(100) = NULL;  -- e.g. 'Harris', or NULL for all counties
DECLARE @state  NVARCHAR(100) = NULL;  -- e.g. 'Texas',  or NULL for all states


SELECT tld.landDescriptionID, tlc.CountyName AS CountyName, tls.StateName AS StateName, tld.BriefLegal, Subdivision, Lot, Block
FROM countyScansTitle.dbo.tbllandDescription tld
JOIN countyScansTitle.dbo.tbllookupCounties tlc ON tlc.CountyID = tld.CountyID
JOIN countyScansTitle.dbo.tbllookupStates tls ON tls.StateID = tlc.StateID
WHERE BriefLegal IS NOT NULL and tlc.countyName = 'Taylor' and tls.StateName = 'Texas'