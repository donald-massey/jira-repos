# LND-8909: Fix Uppercase Source Casing Emptying AbstractDocumentLandDescription

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8909
**Status:** In Progress

**Summary**
`DS9.pres.AbstractDocumentLandDescription` is empty in prod (0 rows), breaking the downstream `abstract_plant_dags` load (Denodo → Elasticsearch → Geo Rendering) that reads it as source. Root cause is a case-sensitivity mismatch on the `source` column introduced in the manufacture step of `land.courthouse-land-data-loader`: `chldl_land_descriptions.source` is written UPPERCASE (`CSTITLE/CHDTITLE/CSDIGITAL/LLM`) while every sibling silver table writes it lowercase. The DS9 abstract-plant publish matches land descriptions by `source` case-sensitively, so zero survive. Done = table repopulated and the casing made consistent.

**Steps to Reproduce**

1. Query `ea_land_prod.gold.chldl_diweb_ds9_abstractdocumentlanddescription` → 0 rows (siblings `abstractdocument` 11.6M, `priorreference` 19M, `grantorgrantee` 36M are populated).
2. `SELECT source, count(*) ... GROUP BY source` on the four `ea_land_prod.silver.chldl_*` tables → `chldl_land_descriptions.source` is UPPERCASE; `chldl_records`, `chldl_prior_references`, `chldl_grantors_grantees` are lowercase.
3. `chldl_land_descriptions` has 53.5M rows with non-null `GeometryWKT` (CSTITLE alone ~23M, 50%), so the data exists — it's filtered out on casing before geometry is evaluated.

**Expected Behavior**
Abstract-plant (CSTITLE / keyed-county) land descriptions with geometry publish to Unity `chldl_diweb_ds9_abstractdocumentlanddescription` and then to `DS9.pres.AbstractDocumentLandDescription`.

**Actual Behavior**
The publish `source` predicate/join in `publish/ds9/ds9_unity_catalog_cache.py` does not match the UPPERCASE land-description `source`, so all land descriptions are dropped and the table writes empty.

**Root Cause**
`manufacture/transformer.py` `transform_land_descriptions` sets `source` lowercase via `_add_source()`, then makes a **second** call to `_trim_replace_empty_values_with_none_and_uppercase_strings(land_descriptions, ['landDescriptionID','recordID','source_id'])` (~lines 205-206). `source` is not in the exclusion list, so it gets upper-cased. The sibling transforms (records / grantors_grantees / prior_references) have no such second call, so they stay lowercase. `manufacture/llm_gold_transformer.py` (~lines 571-573) has the identical defect. NOTE: the local checkout is behind prod (source literals differ: `keyed` vs `cstitle`), so confirm exact line numbers against the deployed commit.

**Proposed Fix**

1. Add `'source'` to the exclusion list on the land-description uppercasing calls in `transformer.py` and `llm_gold_transformer.py` so it stays lowercase and consistent with the other silver tables.
2. Defensive guard: normalize the `source` comparison in `ds9_unity_catalog_cache.py` to case-insensitive (`F.lower(...)`) so future casing drift cannot silently empty the table.
3. Backfill: re-run `manufacture` → `publish_ds9_unity` → `publish_ds9`; verify non-zero counts in both the Unity gold table and `DS9.pres.AbstractDocumentLandDescription`.

**Impact / Severity**
High — website map rendering and any consumer of the abstract-plant land-description dataset get no data; the `abstract_plant_dags` load has no source rows.

**Environment**
Prod. `land.courthouse-land-data-loader` (manufacture + publish_ds9_unity / publish_ds9). Tables: `ea_land_prod.silver.chldl_land_descriptions`, `ea_land_prod.gold.chldl_diweb_ds9_abstractdocumentlanddescription`; sink `DS9.pres.AbstractDocumentLandDescription`.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
