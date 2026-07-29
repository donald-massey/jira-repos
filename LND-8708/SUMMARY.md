# LND-8708 Spike — Summary for Team Discussion

Spike: what happens if we publish `legal_lease` records for leases that have **no** abstract mapping (no `mapping_id`)? Today `kafka-to-adl` drops them from the `legal_lease` ES index by design. This spike quantifies the population, defines *how* we'd emit them, and enumerates per-target consequences. **No production change ships from this card** — it scopes the implementation follow-on.

Full detail in `CLAUDE.md`. Scope-count query in `query_1/unmapped-leases-scope-count.sql`.

---

## Open questions for the team

1. **DS9 — do we ever want these leases there?** Recommendation is to **exclude** zero-mapping leases from DS9 (`include_unmapped=False`) — DS9 already drops them today, so it's zero change / no regression. `mapping_id` is DS9's grain key and almost certainly has a PK / unique index / NOT NULL (Tyler flagged this). If we later *do* want them in DS9, that's a schema decision: **(B)** synthetic sentinel `mapping_id` vs **(C)** alter the DS9 schema. Is exclude-for-now acceptable, and who owns the B/C call if it comes up?

2. **ES consumers — does anything assume `mapping_id` is non-null?** The change makes docs with null `mapping_id` appear in the `legal_lease` index **the website reads**. Before prod, someone who owns the consumers (website, any Databricks/API join) needs to confirm nothing back-references `mapping_id` or assumes it's present. Who can verify this?

3. **Ratify the emission method (union-split).** Emit one lean doc per zero-mapping lease, grained by `lease_id`, unioned onto the untouched mapped path. Alternative is the LND-8426 "fix upstream" path (backfill the mappings in DIV1). Are we agreed the pipeline-side union-split is the direction, with upstream backfill tracked separately?

4. **Scope universe.** The count is defined as *currently-publishable and exported* (`tblexportLog` membership + `recordIsLease=1` + `statusID IN (4,10)`). Is that the right denominator, or do we want *ever-exported* regardless of current status?

---

## What we found

**The core equivalence (verified in producer SQL).** `no mapping_id` ⟺ `no land descriptions in DIV1`. Both producer queries (`div1_get_land_descriptions.sql`, `div1_get_additional_fields.sql`) build land descriptions `FROM tblleaseAbstractMapping` — the descriptions *are* the mapping rows. So a lease with no mapping emits zero description elements → null `mapping_id` after explode. There is no "has descriptions but no mapping" case. This also kills the LND-8426 synthetic-`mapping_id` idea for this population (no CSTitle `LandDescriptionId` to synthesize from either).

**Why we can't just delete the filter.** `filter_records_without_mapping_id` does `where(mapping_id IS NOT NULL)` then `groupBy(mapping_id)`. Removing the `where` collapses every null-mapping row in the batch into a **single null group** — one garbage doc. The filter is a presence-gate *and* the dedup key.

**The method — union-split.** Inside `filter_records_without_mapping_id(flat_df, include_unmapped=…)`:
- `df1` = existing `where(mapping_id NOT NULL).groupBy(mapping_id)` — untouched.
- `df2` = `where(mapping_id IS NULL).groupBy(lease_id)` — one lean doc per zero-mapping lease.
- return `df1.unionByName(df2)` when `include_unmapped=True`, else `df1`.

A mapped lease can never leak into df2: `create_flat_dataframe` coalesces `mapping_id` across all five description arrays, so mapped leases always carry a non-null `mapping_id`. (An earlier pre-filter-on-array-size idea was rejected — it would misclassify PA/OH/WV leases, whose descriptions live in the state-specific arrays with an empty base array.)

**Per-target consequences.**

| Target | Verdict | Why |
|---|---|---|
| **ES `legal_lease`** | Tolerant — **the payoff target** (website reads it). `include_unmapped=True`. | Auto-generated `_id` (no `es.mapping.id`), nothing joins on `mapping_id`. Live-tested in Dev. |
| **DS9** | **Excluded from df2** (`include_unmapped=False`). Zero change, no regression. | `mapping_id` is the grain key + probable PK/unique/NOT NULL. Extending later = schema decision (B/C). |
| **S3** | Tolerant (written analysis). | Parquet sink, no constraint; null tolerated. |
| **Databricks** | Unaffected (written analysis). | Emits no `legal_lease` doc and never gates on `mapping_id`; assignment/depth rows already flow today. |

Note: this is `land-aws-glue`'s `DS9Cache` (writes `pres.legal_lease`). The DS9 write in `land.courthouse-land-data-loader` targets the `abstractdocument*` tables — different model, unaffected.

**Field population of an emitted df2 doc (ES projection).**
- **Populated:** `lease_id`, grantor/grantee (+alias), `instrument_type`, `record_number`, `volume_page`, dates, `image_link`/`di_link`, county/state (+conformed), `api_state`/`api_county`, `state_id`/`county_id`. `polygon_group_id` may be populated (landtrac-polygon path is independent).
- **Null:** `mapping_id`, `abstract_id`, section/township/range (+directions), `survey_name`, `block_section`, `abstract_number`, `quarter_calls`, lat/long, `location`/`location_shape`, `lease_count`(+symb).
- **Not in the ES doc at all:** `record_id` (used only to build the `depthseverances` array, then dropped) and `geom_wkt` (surfaced as `location_shape`). *(Corrects an earlier draft that listed these as populated/null.)*

## Deliverables & how we'll verify

- **Scope number (SQL):** distinct zero-mapping published leases, by state — this equals the expected df2 doc volume. Expect **OH (~16%) / TX (~12%) / WV (~9.5%)** to dominate, **not** PA (~1.15%, well-mapped) per LND-8426.
- **Dev run (ES-only):** reuse the LND-8426 local harness (already runs only `ElasticSearch6Cache`, isolated index) + the union-split edit; publish a couple of zero-mapping lease IDs; capture df2 field population.
- **Clobber check:** assert `df1.lease_id ∩ df2.lease_id = ∅` and df1 count == baseline (structurally guaranteed by the coalesce; confirmed empirically in the ES run).
- **DS9:** no live test — "unchanged" is guaranteed by the `include_unmapped=False` path plus the existing DS9 unit-test fixture staying green.

## Out of scope

- Any production pipeline change (implementation follow-on).
- Upstream DIV1/courthouse mapping backfill (LND-8426 "fix upstream" path).
- Surfacing unmapped *portions* of multi-mapping leases as separate docs.
