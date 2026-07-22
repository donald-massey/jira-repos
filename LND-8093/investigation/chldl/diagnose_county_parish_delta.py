# Databricks notebook cell — why the 118 LND-8093 records are absent from CHLDL indices.
#
# Reads the SAME county_parish_ids Delta table the pipeline joins against
# (transformer._enrich_instruments_by_county_parish_info), so the answer is authoritative.
# CHLDL match key: lower(CountyParishSourceName) == lower(record.CountyName) AND
#                  StateProvinceAbbreviation == record.StateAbbreviation.
# NOTE: this is NOT CS_Stage_Prod.dbo.Vw_County (that view is EOG-keying-scoped and wrong).
# SourceId map: 2=abstractplant, 3=hostedplant, 4=enhancedclerk, 6=historicalplant, 8=chdplant.

import json

env = "prod"  # ES indices verified were prod; swap to "dev" if checking dev.
base = f"s3://land-manufacturing-{env}/data/courthouse-land-data-loader"

# Resolve the versioned path exactly like resolve_storage_location() does.
try:
    version = json.loads(dbutils.fs.head(f"{base}/chldl_version.json", 65536)).get("version")
except Exception:
    version = None
path = f"{base}/{version}/import/full/countyparishdatasource/county_parish_ids" if version \
    else f"{base}/import/full/countyparishdatasource/county_parish_ids"
print("version:", version, "\nreading:", path)

spark.read.format("delta").load(path).createOrReplaceTempView("county_parish")

# The 8 counties in question (state abbrev, CSTitle CountyName spelling).
rec = spark.createDataFrame(
    [("LA", "St. Landry"), ("TX", "McMullen"), ("TX", "Guadalupe"), ("ND", "Cavalier"),
     ("KS", "Decatur"), ("KS", "Greeley"), ("UT", "Morgan"), ("PA", "Washington")],
    ["StateAbbrev", "CSTitleCountyName"])
rec.createOrReplaceTempView("rec")

# Q1) Replicate the pipeline join EXACTLY. 'NO JOIN MATCH' => dropped from every index on
#     condition 2. Otherwise SourceId shows which plant index(es) that county can reach.
print("=== Q1: exact-join replication ===")
spark.sql("""
    SELECT r.StateAbbrev, r.CSTitleCountyName, cp.CountyParishSourceName, cp.SourceId,
           CASE WHEN cp.CountyParishId IS NULL THEN 'NO JOIN MATCH (dropped everywhere)'
                ELSE 'matched' END AS join_status
    FROM rec r
    LEFT JOIN county_parish cp
           ON cp.StateProvinceAbbreviation = r.StateAbbrev
          AND lower(cp.CountyParishSourceName) = lower(r.CSTitleCountyName)
    ORDER BY r.StateAbbrev, r.CSTitleCountyName, cp.SourceId
""").show(100, truncate=False)

# Q2) Loose lookup — actual spellings/SourceIds held for these counties, to tell
#     "not a plant county" apart from a name-spelling mismatch (e.g. the 'St. Landry' dot).
print("=== Q2: loose LIKE lookup ===")
spark.sql("""
    SELECT StateProvinceAbbreviation, CountyParishSourceName, CountyParishName,
           CountyParishId, SourceId, CountyType
    FROM county_parish
    WHERE (StateProvinceAbbreviation='LA' AND lower(CountyParishSourceName) LIKE '%andry%')
       OR (StateProvinceAbbreviation='TX' AND lower(CountyParishSourceName) LIKE '%mullen%')
       OR (StateProvinceAbbreviation='TX' AND lower(CountyParishSourceName) LIKE '%uadalupe%')
       OR (StateProvinceAbbreviation='ND' AND lower(CountyParishSourceName) LIKE '%avalier%')
       OR (StateProvinceAbbreviation='KS' AND lower(CountyParishSourceName) LIKE '%ecatur%')
       OR (StateProvinceAbbreviation='KS' AND lower(CountyParishSourceName) LIKE '%reeley%')
       OR (StateProvinceAbbreviation='UT' AND lower(CountyParishSourceName) LIKE '%organ%')
       OR (StateProvinceAbbreviation='PA' AND lower(CountyParishSourceName) LIKE '%ashington%')
    ORDER BY StateProvinceAbbreviation, CountyParishSourceName, SourceId
""").show(200, truncate=False)
