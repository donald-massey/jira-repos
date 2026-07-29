# Databricks notebook source
# MAGIC %md
# MAGIC # CH3.0 County OCR / IA-Summary publish-gap tracer
# MAGIC
# MAGIC Finds **where `OCRs3Path` drops out** in the courthouse-land-data-loader chain for
# MAGIC courthouse**Direct**Title (CHD) records, so we know how far up to roll back the
# MAGIC status dates.
# MAGIC
# MAGIC Data-source mapping (from `acquire/databases.py`):
# MAGIC - `KeyedCountyDataSource`            -> cstitle  (countyScansTitle)      -> `keyedcountydatasource`
# MAGIC - `NonKeyedAndHistoricalDataSource`  -> **cdtitle (courthouseDirectTitle)** -> `nonkeyedandhistoricaldatasource`  ← our records
# MAGIC - `EnhancedClerkDataSource`          -> csdigital (CS_Digital)           -> `enhancedclerkdatasource`  (OCR paths live here, joined by recordID)
# MAGIC
# MAGIC Chain: **import** (`import/full/...`) -> **manufacture** (`stage/full/records`) -> **publish** (ES).
# MAGIC The publish carries `OCRs3Path` straight from the manufactured `records`, so if it's null
# MAGIC in `stage/full/records` the fix is upstream; if it's populated there, the fix is publish-only.

# COMMAND ----------

dbutils.widgets.text("env", "prod", "ENV_ENVIRONMENT (dev/prod)")
dbutils.widgets.text("version", "", "chldl version (blank = read chldl_version.json)")
dbutils.widgets.text("county", "", "County name (contains, case-insensitive)")
dbutils.widgets.text("state", "", "State abbreviation")

ENV = dbutils.widgets.get("env").strip()
COUNTY = dbutils.widgets.get("county").strip().upper()
STATE = dbutils.widgets.get("state").strip().upper()

JOB_NAME = "courthouse-land-data-loader"
BASE = f"s3://land-manufacturing-{ENV}/data/{JOB_NAME}"

# version: read chldl_version.json unless overridden
import json
version = dbutils.widgets.get("version").strip()
if not version:
    version = json.loads(dbutils.fs.head(f"{BASE}/chldl_version.json"))["version"]
ROOT = f"{BASE}/{version}"
print(f"ENV={ENV}  version={version}\nROOT={ROOT}\nFilter: County contains '{COUNTY}', State='{STATE}'")

# COMMAND ----------

# Cache locations
MFG_RECORDS       = f"{ROOT}/stage/full/records"
OCR_FULL          = f"{ROOT}/import/full/enhancedclerkdatasource/record_ocr_s3_path"
OCR_INCR          = f"{ROOT}/import/increment/enhancedclerkdatasource/record_ocr_s3_path"
CDTITLE_RECORDS   = f"{ROOT}/import/full/nonkeyedandhistoricaldatasource/records"

STATUS_IMPORT = f"{ROOT}/import/full/status.json"
STATUS_STAGE  = f"{ROOT}/stage/full/status.json"
STATUS_STAGE_INCR = f"{ROOT}/stage/increment/status.json"
STATUS_PUBLISH = f"{ROOT}/publish/status_elasticsearch.json"

import pyspark.sql.functions as F


def col_ci(df, name):
    """Resolve a column name case-insensitively (schemas vary keyed vs nonkeyed)."""
    lookup = {c.lower(): c for c in df.columns}
    return lookup.get(name.lower())

# COMMAND ----------

# MAGIC %md ## 0. Status dates — where each stage currently thinks it has processed to

# COMMAND ----------

for label, path in [("IMPORT full", STATUS_IMPORT), ("STAGE full", STATUS_STAGE),
                    ("STAGE increment", STATUS_STAGE_INCR), ("PUBLISH (ES)", STATUS_PUBLISH)]:
    try:
        print(f"{label:18} {path.split('/')[-1]:22} -> {dbutils.fs.head(path)}")
    except Exception as e:
        print(f"{label:18} (missing) {path}  [{type(e).__name__}]")

# COMMAND ----------

# MAGIC %md ## 1. MANUFACTURE cache — is OCRs3Path populated for target county CHD records?
# MAGIC This is the decisive check. Publish reads `OCRs3Path` straight from here.

# COMMAND ----------

mfg = spark.read.format("delta").load(MFG_RECORDS)
print("stage/full/records schema:")
mfg.printSchema()

cn, st = col_ci(mfg, "CountyName"), col_ci(mfg, "state")
rid, ocr = col_ci(mfg, "recordID"), col_ci(mfg, "OCRs3Path")
src, mod = col_ci(mfg, "source"), col_ci(mfg, "_ModifiedDateTime")

county_df = mfg.filter(F.upper(F.col(cn)).contains(COUNTY) & (F.upper(F.col(st)) == STATE))
total = county_df.count()
missing = county_df.filter(F.col(ocr).isNull()).count()
print(f"\n{COUNTY} ({STATE}) manufactured records: {total}")
print(f"  with OCRs3Path:    {total - missing}")
print(f"  MISSING OCRs3Path: {missing}   <-- if large, the OCR data never reached manufacture")

# COMMAND ----------

# Break the missing-OCR records down by source + modified month
if src:
    print("Missing-OCR records by source:")
    county_df.filter(F.col(ocr).isNull()).groupBy(src).count().show(truncate=False)

print("Missing-OCR records by _ModifiedDateTime month:")
(county_df.filter(F.col(ocr).isNull())
 .groupBy(F.date_trunc("month", F.col(mod)).alias("mfg_modified_month"))
 .count().orderBy("mfg_modified_month").show(truncate=False))

# keep the missing recordIDs to trace upstream
missing_ids = county_df.filter(F.col(ocr).isNull()).select(F.col(rid).alias("recordID"))
missing_ids.cache()
print(f"missing_ids count = {missing_ids.count()}")

# COMMAND ----------

# MAGIC %md ## 2. IMPORT OCR cache — did the OCR paths get imported at all?
# MAGIC The OCR paths come from CS_Digital (`enhancedclerkdatasource`) and join to CHD records by recordID.
# MAGIC If the missing recordIDs ARE here (with a recent date), manufacture just hasn't re-run.
# MAGIC If they're NOT here, acquire hasn't imported them and you must roll the import date back too.

# COMMAND ----------

ocr_full = spark.read.format("delta").load(OCR_FULL)
print("record_ocr_s3_path (import/full) schema:")
ocr_full.printSchema()

o_rid = col_ci(ocr_full, "recordID")
o_mod = col_ci(ocr_full, "_ModifiedDateTime")

hit = ocr_full.join(missing_ids, ocr_full[o_rid] == missing_ids["recordID"], "inner")
print(f"\nOf {missing_ids.count()} records missing OCRs3Path in manufacture:")
print(f"  present in import/full OCR cache: {hit.count()}")
print("\n_ModifiedDateTime distribution of those matches:")
(hit.groupBy(F.date_trunc("month", F.col(o_mod)).alias("ocr_import_month"))
 .count().orderBy("ocr_import_month").show(truncate=False))

# COMMAND ----------

# Increment OCR cache (may or may not exist depending on last run mode)
try:
    ocr_incr = spark.read.format("delta").load(OCR_INCR)
    oi_rid = col_ci(ocr_incr, "recordID")
    print(f"import/increment OCR rows: {ocr_incr.count()}")
    print(f"  of our missing set present in increment: "
          f"{ocr_incr.join(missing_ids, ocr_incr[oi_rid]==missing_ids['recordID'],'inner').count()}")
except Exception as e:
    print(f"No import/increment OCR cache ({type(e).__name__}) — full-mode last run.")

# COMMAND ----------

# MAGIC %md ## 3. Verdict
# MAGIC Not a loader bug — the increment path (import OCR increment -> `increment_child_records` ->
# MAGIC pull parent record -> left-join `OCRs3Path` -> publish upsert) is built for exactly this
# MAGIC OCR-only-change case and is correct. This is an operational cycle gap.
# MAGIC
# MAGIC - **OCRs3Path populated in manufacture (missing ~ 0):** gap is publish-only; re-run an INCREMENT publish covering the records.
# MAGIC - **Missing in manufacture, present in import OCR cache:** re-run manufacture -> publish via the INCREMENT path.
# MAGIC - **Missing in import OCR cache too:** roll the IMPORT date back to before the OCR batch, re-run acquire -> manufacture -> publish so the OCR increment is re-captured.
# MAGIC
# MAGIC WARNING: do NOT just roll back the stage date. In FULL mode manufacture filters records by the
# MAGIC record's own `_ModifiedDateTime` (data_manufacturer.py:65-68), NOT the OCR date — OCR-only
# MAGIC changes have old row dates and get filtered out. Drive the fix through the INCREMENT path (roll
# MAGIC the IMPORT date back, keep dates chained so each stage stays in increment mode), or do a full
# MAGIC reload (re-manufactures all records unconditionally).
