# LND-8708: Spike: publish LegalLeases without abstract/mapping entries

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8708
**Status:** Backlog

## Summary

Spike. Investigate the consequences of publishing `legal_lease` records for leases that have **no** `tblAbstract` / `tblleaseAbstractMapping` entry (and therefore no `mapping_id`). LND-8426 established that such leases reach Kafka but are dropped from the `legal_lease` Elasticsearch index by design. This card does **not** change the pipeline — it quantifies the affected population, characterizes what an emitted record would look like, and enumerates the per-target consequences so a follow-on implementation ticket can be scoped with real data.

## Background

Per LND-8426, `kafka-to-adl` drops these records at `filter_records_without_mapping_id` (`jobs/kafka_to_adl/src/kafka_to_adl.py`):

```python
flat_df = flat_df.where(F.col("mapping_id").isNotNull())   # drops unmapped rows
flat_df = flat_df.groupBy("mapping_id").agg(*first_cols)    # grain = one doc per mapping_id
```

The second line is the reason the filter exists: **one** `legal_lease` document = one lease->abstract mapping (`mapping_id`). A lease with no mapping has no document identity, not merely a dropped row. Naively removing the `where(...)` collapses every null-mapping row across the whole batch into a single `null` group — one garbage document — which is why the filter cannot simply be deleted.

## Scope of investigation

**Key equivalence (verified in the producer SQL):** `no mapping_id` ⟺ `no land descriptions in DIV1`. Both `div1_get_land_descriptions.sql` and `div1_get_additional_fields.sql` select `FROM tblleaseAbstractMapping m JOIN tblAbstract a`, with `legacy_mapping_id = m.mappingid`. The land descriptions in the Kafka message *are* the mapping rows — every description element that exists carries a non-null `mapping_id` by construction, so there is no "has descriptions but null mapping_id" case. A lease with no `tblleaseAbstractMapping` entry emits zero land-description elements across **all five** arrays (`land_descriptions` + `ohio`/`ohio_plss`/`pennsylvania`/`west_virginia`), which yields a null `mapping_id` after `explode_outer`. This validates the scope-count anti-join and rules out LND-8426's synthetic-`mapping_id` fallback for this population (there is no CSTitle `LandDescriptionId` to synthesize from — those rows don't exist either).

Populations:

- **Zero-mapping leases** — no abstract mapping anywhere (⟺ no land descriptions); the lease is entirely absent from `legal_lease` today (e.g. LND-8426 record `4696618` / `a688f5be-8530-4647-b73d-089c185c8262`, COLUMBIA PA). This is df2's target population.
- **Partial-mapping leases** — a lease with multiple mappings emits multiple `mapping_id`-grained docs (df1). Because `create_flat_dataframe` coalesces `mapping_id` across all five arrays, a mapped lease **never** produces a null-`mapping_id` row, so it cannot leak into df2. The clobber-check confirms this empirically.

## Proposed approach under test (union-split)

Do not re-grain the existing path. Split **after** `create_flat_dataframe`, inside `filter_records_without_mapping_id`, parameterized by `include_unmapped`:

- **df1** — the current, untouched `where(mapping_id IS NOT NULL).groupBy("mapping_id")` path. Mapped leases stay byte-for-byte identical by construction.
- **df2** — `where(mapping_id IS NULL).groupBy("lease_id")` — one lean doc per zero-mapping lease.
- Result = `df1.unionByName(df2)` when `include_unmapped=True`; plain df1 when `False`.

Because the coalesce in `create_flat_dataframe` fills `mapping_id` from whichever of the five arrays is populated, a mapped lease produces no null-`mapping_id` row and cannot appear in df2 — so the anti-join against df1's `lease_id` that the original ticket described is redundant and is dropped. The post-explode null test is inherently state-correct (no per-array size predicate to maintain). The spike validates this shape produces the intended records and measures whether df1's document count for mapped leases is unchanged.

> Note: an earlier revision proposed a *pre-filter before explode* on `land_descriptions` array size. Rejected — PA/OH/WV leases carry their descriptions in the state-specific arrays with an empty base `land_descriptions`, so a base-array size check would misclassify mapped Marcellus leases as zero-mapping and clobber them. The post-explode `mapping_id`-null split above avoids this entirely.

## Two measurements

1. **Source-side scope count (SQL).** Of the leases the producer published to Kafka (`tblexportLog.LeaseID` -> `tblRecord.recordID`), how many have zero abstract mapping in DIV1? Break out by state. Per LND-8426's drop-rate analysis, expect **OH (~16%), TX (~12%), WV (~9.5%)** to dominate — **not** PA (well-mapped at ~1.15%). Query attached (`unmapped-leases-scope-count.sql`) — single linked-server anti-join via `LinktoDiv1Repl`.
2. **Pipeline-side emission (ES-only Dev run).** Run the modified kafka-to-adl job locally against a couple of published zero-mapping leases; capture the df2 records and field population from the ES `legal_lease` output.

## Targets

All four caches subclass `LegalLeaseOutputCache`, but only **three actually call** `filter_records_without_mapping_id`: `S3Cache` and `DS9Cache` (via `create_legal_lease_dataframe`) and `ElasticSearch6Cache` (directly, line 721). **`DatabricksCache` does not** — its `update()` returns early unless `dataset=='legal_lease'`, then writes only `lease_assignment_detail` and `depth_clause_detail`, grained by exploding `assignments`/`depth_clauses`, with no `mapping_id` gate. It emits no `legal_lease` document at all.

Per-target stance:

- **ES (`legal_lease`)** — the payoff target; this is the index the website reads. `include_unmapped=True`. Structurally tolerant of null `mapping_id`: the write sets no `es.mapping.id`, so `_id` is auto-generated (no collision), and nothing in the job joins on `mapping_id`. **Live-tested in Dev.**
- **DS9** — `include_unmapped=False`: **excluded from df2 by design.** DS9 already drops these leases today, so this is zero change / no regression. `mapping_id` is DS9's grain key and almost certainly carries a PK / unique index / NOT NULL constraint (flagged by T. Jordan); even a bare unique index rejects the 2nd null per SQL Server semantics. Extending df2 to DS9 later requires a schema decision — deferred to the implementation ticket. **Not live-tested**; "unaffected" is guaranteed by the `include_unmapped=False` code path plus the existing DS9 unit-test fixture (`tests/.../output_ds9_cache_legal_lease.json`) staying green.
  - Note: this is `land-aws-glue`'s `DS9Cache` writing `pres.legal_lease`. The separate DS9 write in `land.courthouse-land-data-loader` (`publish/ds9/ds9_cache.py`) targets the courthouse `abstractdocument*` tables — different model, no `mapping_id`, unaffected.
- **S3** — `include_unmapped=True`; written analysis. Parquet sink, no constraint; null `mapping_id` tolerated.
- **Databricks** — written analysis. No `legal_lease` doc emitted, no `mapping_id` gate; zero-mapping leases' assignments/depth rows already flow today regardless of mapping. Unaffected by this change.

## Acceptance criteria

- Scope number: count of Kafka-published leases with zero abstract mapping, by state.
- Sample emitted docs: actual df2 records from the ES Dev run, enumerating which `legal_lease` fields are populated vs. null. Field expectations are against the **ES `legal_lease` projection** (lines 701–719):
  - Expected **null** (present but null for df2): `mapping_id`, `abstract_id`, `section`/`township`/`range` (+ directions), `survey_name`, `block_section`, `abstract_number`, `quarter_calls`, `latitude`/`longitude`, `location`/`location_shape`, `lease_count`/`lease_count_symb`.
  - Expected **populated**: `lease_id`, `grantor_name`, `grantee_name`/`grantee_alias`, `instrument_type`, `record_number`, `volume_page`, the date fields, `image_link`/`di_link`, `county_parish`/`county_state`/`state_province`, `api_state`/`api_county`, `state_id`/`county_id`, conformed county/state/country/basin/play. `polygon_group_id` may be populated (landtrac-polygon path is independent of mapping — true for 4696618).
  - **Not in the ES projection at all** (neither populated nor null — absent columns): `record_id` (consumed only by the `depthseverances` UDF, then dropped) and `geom_wkt` (surfaced as `location_shape`). Earlier drafts wrongly listed `record_id` as expected-populated and `geom_wkt` as expected-null.
- DS9 verdict: **descoped** — DS9 excludes df2 (`include_unmapped=False`), so there is no null-`mapping_id` row to test. Verification that DS9 is unchanged = the existing DS9 unit-test fixture stays green. The probable `mapping_id` constraint is recorded as deferred context for the implementation ticket (schema-introspection query optional, not required for this spike).
- Per-cache consequence table: ES (tolerant, live-proven) / DS9 (excluded by design, unchanged) / S3 (tolerant, analysis) / Databricks (unaffected, analysis) — with why.
- Clobber check: assert `df1.lease_id ∩ df2.lease_id = ∅` and df1 count == baseline; structurally guaranteed by the coalesce, confirmed empirically in the ES run.
- ES-consumer check: docs with null `mapping_id` will now appear in the index the website reads — confirm the website / `legal_lease` consumers don't assume `mapping_id` is non-null (LND-8426 downstream-consumer warning, applied to ES).
- Recommendation for the implementation ticket: go/no-go per target + the union-split design + the DS9 B-vs-C decision (sentinel `mapping_id` vs schema change).

## Out of scope

- Any production pipeline change (deferred to the implementation follow-on).
- Upstream courthouse/DIV1 data-loading fixes (the LND-8426 "fix it upstream" path) — tracked separately if pursued.
- Surfacing the unmapped _portions_ of partial-mapping leases as separate docs (rejected; excluded from df2).

## References

- LND-8426 — Recent PA LegalLeases Not Published (parent investigation)
- `LND-8426-pa-mapping-checks.sql` — source-data checks / mapping_id path
- `LND-8426-local-dev-handoff.md` — Dev reproduction (producer -> Kafka -> glue -> ES)
- `jobs/kafka_to_adl/src/kafka_to_adl.py` — `filter_records_without_mapping_id`
- Attached: `unmapped-leases-scope-count.sql` — scope-count query

## Approach

### Query 1 — Scope count (SQL)

Run `query_1/unmapped-leases-scope-count.sql` on CSTitle server (`aus2-dtf-pap01v.na.drillinginfo.com`).

Extend the attached query with:
- State breakout via `tblRecord.stateID → tblLookupStates.stateAbbreviation` (same join used in LND-8426 PASS B)
- `statusID IN (4, 10)` filter to restrict to publishable/active records
- Stage DIV1 mapped leases via `OPENQUERY([LinktoDiv1Repl], 'SELECT DISTINCT LeaseID FROM div1_Daily.dbo.tblleaseAbstractMapping')` into `#mapped_leases` — same pattern as LND-8426 PASS B

Output: count of zero-mapping leases by state, for the scope-number acceptance criterion.

### Query 2 — Pipeline-side emission (Dev run)

> Runbook: `query_2/DEV-RUN-PLAN.md` (ES-only). Test-data selection: `query_2/sample-zero-mapping-leaseids.sql`. **Gated on the team discussion** — do not execute until the SUMMARY.md questions are resolved.

**Implementation under test — union-split inside `filter_records_without_mapping_id`:**

Parameterize the method `filter_records_without_mapping_id(flat_df, include_unmapped=False)`:
- `df1 = flat_df.where(mapping_id IS NOT NULL).groupBy("mapping_id").agg(first(*))` — unchanged.
- `df2 = flat_df.where(mapping_id IS NULL).groupBy("lease_id").agg(first(*))` — one lean doc per zero-mapping lease.
- return `df1.unionByName(df2)` if `include_unmapped` else `df1`.

Callers: ES and S3 pass `include_unmapped=True`; DS9 keeps the default `False`. Single touch point, so the three caches can't drift; DS9's default-`False` branch must return the byte-identical df1 (guarded by the existing DS9 unit-test fixture).

**Dev run (ES-only):**
- Use query_1 results to select a couple of known zero-mapping lease IDs (state is immaterial — all five description arrays are empty, so behavior is state-independent; state only matters for the scope count).
- Publish them to the test Kafka topic using the LND-8426 producer debug setup (`dp.pres.legalleases.v3_test`).
- Reuse the LND-8426 local glue harness **unchanged** — it already runs only `ElasticSearch6Cache` (isolated index, `manage_alias=False`) — plus the union-split edit.
- Capture the df2 output to enumerate field population (against the ES projection list in Acceptance criteria).
- No DS9 in the Dev run; no DS9 dev creds; no live insert (DS9 excludes df2, so there's nothing to observe).

### Open investigations before implementation ticket

- **Mechanism decision (mapping_id generation for non-geom records)**: to surface these records we need to generate `mapping_id` values. Two options — (a) adapt an existing script in the legal-lease pipeline, or (b) add a new dedicated script. This and the DS9 B-vs-C item below are candidates to move to the task card; **hold on creating the task card until a mechanism is chosen.** Records can be validated through the Dev pipeline in the meantime.
- **DS9 handling (B vs C)**: if the implementation ticket later wants zero-mapping leases in DS9 too, decide between a synthetic sentinel `mapping_id` (e.g. negative id derived from `lease_id`, avoiding collision with positive DIV1 `mappingid`; check the LND-8426 ID-space warning) vs. a DS9 schema change (drop NOT NULL / repoint the key). Out of scope here.
- **ES-consumer assumption**: confirm nothing querying the `legal_lease` index assumes `mapping_id` is non-null before shipping the change to prod.

### Resolved during spike planning

- **DatabricksCache** — resolved from code: emits no `legal_lease` doc and never gates on `mapping_id`; zero-mapping leases' assignment/depth rows already flow today. Unaffected.
- **Partial-mapping clobber** — resolved by design: the coalesce prevents mapped leases from producing null-`mapping_id` rows, so df2 cannot contain a mapped lease; the anti-join is unnecessary. Confirmed by the clobber-check in the ES run.

## Completed

- **Query 1 — scope count (2026-07-29).** 88,643 zero-mapping published leases total (= expected df2 volume). TX 53,085 (60%), WV 15,573, OH 13,436 (top 3 = 93%); PA only 658. By-state reconciles exactly to the total (no `UNKNOWN` bucket → clean `stateID`). Results: `query_1/scope-count-results.md`.

- **Query 3 — geometryless leases + georendering behavior (2026-08-11).** Identified leases already published *without geometry* in the ES `legal_lease` index: **219,765** docs missing both `location` and `location_shape`. Sample of 10 → all **mapped** (`mapping_id` populated, `svgPolygonGroupDetailId` NULL in DIV1), i.e. a **different population** from this card's zero-mapping leases. Traced to DS9 `pres.legal_lease`:
  - Geometry is **`mapping_id`-grained**; the geometry-typed `GEOM` column is **null table-wide** — the real point source is `geom_wkt` / `latitude` / `longitude`, derived from the abstract/survey PLSS lookup in producer `land_descriptions.py:28-40` (TX: `county_id+abstract_number`; non-TX: `county+section/township/block`). A mapping with no lookup match gets a null point. Separate from the SVG polygon path (`location_shape`), null when DIV1 `svgPolygonGroupDetailId` is null.
  - **Blocker result:** 113,655 leases (178,913 mappings) already live in prod DS9 with null geometry and the site does **not** break — georendering degrades to **searchable-but-unpinned** (map/tile spatial query skips null-geometry rows; attribute/search path returns them). Geometry-null is therefore tolerated and is **NOT** the DS9 blocker (that's `mapping_id` NOT NULL/PK). This refutes the "hard render failure" hypothesis in comment 5097097.
  - Decomposition: 219,765 geometryless mappings = 178,913 in 113,655 fully-unrenderable leases (fix target) + 40,852 tract-level gaps on leases that still pin via a sibling mapping. Behavioral confirmation on live site still pending (`query_3/ds9-sample-unrenderable-leases.sql`). Queries: `query_3/`.
