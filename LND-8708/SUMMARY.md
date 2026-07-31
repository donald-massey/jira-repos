# LND-8708 Spike — Summary for Team Discussion

Spike: what happens if we publish `legal_lease` records for leases that have **no** abstract mapping (no `mapping_id`)? Today `kafka-to-adl` drops them from the `legal_lease` ES index by design. This spike quantifies the population, defines *how* we'd emit them, and enumerates per-target consequences. **No production change ships from this card** — it scopes the implementation follow-on.

Full detail in `CLAUDE.md`. Scope-count query in `query_1/unmapped-leases-scope-count.sql`.

---

## Open Questions for the Team

0. **⛔ BLOCKER — Product decision pending: these leases are searchable but cause a hard map-render failure.** The website's georendering service reads the geometry from a column **in DS9** to place a lease on the map. Under the union-split, df2 publishes to the ES `legal_lease` index — so the lease is **searchable and appears in results** — but df2 is **excluded from DS9** (`include_unmapped=False`), so georendering finds **no DS9 row at all**. That's a lookup miss → **hard render failure**, not a present-but-null geometry that could degrade gracefully. This is inherent to the population: `no mapping_id` ⟺ `no land descriptions` ⟺ no geometry to write. A customer would get a search hit that breaks when they try to view it on the map, which is likely worse than the lease being absent entirely (today's behavior). **Confirm desired behavior with product before scoping the implementation ticket** — the real options are (a) leave them dropped, (b) publish to ES only and have the site handle the missing-geometry case gracefully (no map pin rather than an error), or (c) also land them in DS9 with real or sentinel geometry (the B/C DS9 decision in Q2). Note: the `polygon_group_id` on the ES doc does **not** rescue this — georendering reads DS9's geometry column, not ES, so a populated polygon id is never consulted on the render path unless georendering is repointed. Owner: D. Massey taking to senior manager / product.

1. **Fix in the pipeline or upstream?** Recommendation: emit these leases in the pipeline via the union-split in `land-aws-glue`'s `kafka-to-adl` (`filter_records_without_mapping_id`, `jobs/kafka_to_adl/src/kafka_to_adl.py:326`), so leases with no `tblleaseAbstractMapping` entry get emitted as one lean doc per zero-mapping lease. The alternative is backfilling the mappings in DIV1 (LND-8426's upstream path). Agree the pipeline is the direction, with upstream backfill tracked separately?

2. **DS9 — do we ever want these leases there?** Recommendation: **exclude** them (`include_unmapped=False`).
   - **Zero change / no regression** — DS9 already drops these today.
   - **Why it must opt out:** `mapping_id` is DS9's grain key, almost certainly PK / unique / NOT NULL (Tyler flagged this).
   - **Wiring:** new `include_unmapped=False` param on `filter_records_without_mapping_id` (`kafka_to_adl.py:326`), threaded through the shared `create_legal_lease_dataframe` (`:333`). ES → `True` (`:721`), S3 → `True` (`:559`), DS9 → default `False` (`:488`), so DS9 stays byte-identical.
   - **If we later want them in DS9:** schema decision — **(B)** synthetic sentinel `mapping_id` vs **(C)** alter the schema.
   - **Ask:** exclude-for-now acceptable, and who owns the B/C call?

3. **ES consumers — does the site assume `mapping_id` is present?** The change makes docs with null `mapping_id` appear in the `legal_lease` index (alias `legal-leases`) **the website reads**. `mapping_id` is a real queryable field in the index (`type: long`), so df2 docs won't break indexing — they'll just omit the field — but any read that does `exists: mapping_id`, filters/sorts on it, or dedups on one-doc-per-`mapping_id` would silently exclude or mis-handle them. **The Dev run tests this directly:** it's a **local, no-Jenkins** run (see below) that repoints the **real dev `legal-leases` alias** at an index containing df2 docs, exercises the dev site, then swaps the alias back — so the dev-site consumer half *is* covered, not just ES indexing mechanics. The remaining gate is any **consumer beyond the dev site** (prod site build, other `legal_lease`/`legal-leases` readers): confirm none depend on `mapping_id` being present before shipping to Prod. Pre-Prod consideration, not a blocker for the Dev test.

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

- **Scope number (SQL) — DONE:** **88,643** zero-mapping published leases = the expected df2 doc volume added to the `legal_lease` index. **TX 53,085 (60%)**, WV 15,573, OH 13,436 — top 3 = 93%. PA only 658 (confirms LND-8426: PA well-mapped, TX is the real weight). By-state rows reconcile exactly to the total (no unmatched-`stateID` tail). Full table: `query_1/scope-count-results.md`.
- **Dev run (ES-only, local / no Jenkins):** control volume at the **producer** — publish 1,000 mapped + 1,000 unmapped leases (`query_2/sample-2000-split-leaseids.sql`) to a **fresh test topic**, so the glue Kafka read is fast and no in-job `.limit()` caps are needed. Glue runs the union-split, stamps df2 with the **Washington-coast sentinel** (§7), writes a new `legal_lease_<ts>` index with `manage_alias=False`, then **manually swaps the real dev `legal-leases` alias** to it (no-delete → instant swap-back), exercises the dev site, and swaps back. One run answers **three** things: df2 emit, ES-consumer tolerance (Q3), and the sentinel behaves (excluded from county searches). Runbook: `query_2/DEV-RUN-PLAN.md`.
- **Clobber check:** assert `df1.lease_id ∩ df2.lease_id = ∅` (load-bearing; structurally guaranteed by the coalesce). With volume controlled at the producer (no caps), also diff the **PINNED_MAPPED `lease_id`** doc against an `include_unmapped=False` baseline — it must be identical (df1 is untouched by the union-split and the df2-only WA stamp). See runbook §6.
- **DS9:** no live test — "unchanged" is guaranteed by the `include_unmapped=False` path plus the existing DS9 unit-test fixture staying green.

## Out of scope

- Any production pipeline change (implementation follow-on).
- Upstream DIV1/courthouse mapping backfill (LND-8426 "fix upstream" path).
- Surfacing unmapped *portions* of multi-mapping leases as separate docs.
