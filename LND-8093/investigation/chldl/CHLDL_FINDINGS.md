# LND-8093 — CHLDL (courthouse-land-data-loader) verification

## Question
Did the 131 LND-8093 backfilled records (`tblS3Image`, `_ModifiedBy='LND-8093'`) propagate
into the CHLDL Elasticsearch indices, specifically `courthouse-abstractplants_dbpipeline-*`?

## Answer
The backfill is working. Every record CHLDL ingests received its LND-8093 image. The records
not present are excluded by CHLDL's own selection rules, not by any backfill failure — and
none of these counties are abstract-plant counties, so 0 belong in abstractplants.

## How CHLDL selects (two required conditions, per `record_transforms.filter_records_by_product`)
1. **source** matches the plant type: abstractplants→`keyed`; chdplants→`nonkeyed` or
   `keyed`+GathererID∈[12,15,20]; enhancedclerks→`enhancedclerk`; historicalplants→`keyed`+old.
2. **county carries that plant type's SourceId** in the countyparish master
   (2=abstract, 4=enhancedclerk, 8=chd), left-joined on state + `lower(CountyParishSourceName)`.
   No match ⇒ dropped from every index.

ES `_id` is the recordID; `ImageLocation` is `s3FilePath.lower()`, so a propagated record
shows the `s3://enverus-courthouse-prod-chd-plants/...` path.

## Result (verified against prod `county_parish_ids`, version 20260608075104)
| Group | Count | Outcome |
| --- | --- | --- |
| Present | 13 | 12 McMullen → `enhancedclerks` (SourceId 4); 1 Guadalupe → `chdplants` (SourceId 8). All carry the chd-plants ImageLocation — backfill propagated. |
| Absent — county out of CHLDL scope | 111 | St. Landry LA (105), Cavalier ND (2), Decatur KS (1), Greeley KS (1), Morgan UT (1), Washington PA (1). No countyparish designation → dropped from every index. |
| Absent — wrong source for designation | 7 | McMullen keyed records (GathererID 12). McMullen is designated enhancedclerk (SourceId 4) only; these aren't enhancedclerk-source and McMullen has no chd SourceId 8, so no (source × SourceId) pair matches. |

13 + 111 + 7 = 131.

Guadalupe confirms the model: it carries SourceId 4 **and** 8, and its one keyed+gatherer-12
record correctly landed in chdplants (8).

## Relation to the legal_lease finding
Same records, different filter. legal_lease excluded the St. Landry block on Div1 instrument
category (`category=2`); CHLDL excludes on source × county-designation. The St. Landry records
are geophysical-permit/option documents that are neither Div1 leases nor CHLDL plant records,
so they legitimately fall out of both pipelines for different reasons.

## Reproduce
- ES presence: `investigation/chldl/query_chldl_es.py` (or `check_chldl_abstractplants_index.txt` in Kibana).
- County designations: `investigation/chldl/diagnose_county_parish_delta.py` (Databricks).
