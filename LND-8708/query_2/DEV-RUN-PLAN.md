# LND-8708 Query 2 — Dev-run plan (ES-only)

**Do not start until the team discussion resolves the SUMMARY.md questions** (esp. the site-team `mapping_id` check and the pipeline-vs-upstream direction). This is the runbook to execute once it's a go.

**No Jenkins, no prod.** The whole thing runs from a **local** `run_job_locally()` branch against the **dev** ES cluster (same harness as LND-8426). The only externally-visible effect is a **reversible repoint of the dev `legal-leases` alias** during the validation window — old index is never deleted, so swap-back is instant. Nothing merges; revert = swap the alias back and discard the local branch.

Goals:
1. Prove the union-split emits the intended zero-mapping (df2) docs into a `legal_lease` index and does not clobber the mapped (df1) path.
2. **Verify the ES consumer (Q3):** put df2 docs behind the real `legal-leases` alias the dev site reads, and confirm null-`mapping_id` docs don't break the site's `legal_lease` queries. A scratch alias can't prove this — the site only reads `legal-leases`.
3. **Test the Washington-coast sentinel (§7):** stamp df2 docs with the producer's existing offshore-WA point (`−129.134, 46.6723`) and prove it indexes and is **excluded from county searches** but **included in an offshore search** — answering the location question with data, not a team decision.

ES-only — DS9/S3/Databricks are covered by written analysis (see CLAUDE.md Targets).

---

## 0. Prereqs

- VPN up; Docker Desktop running.
- **Fresh AWS session creds** (the producer's IIE enricher hits S3 — stale keys fail at runtime).
- Both repos on a scratch branch off `LND-8426` (which already has the local-dev harness). Revert all debug overrides before any merge.
- **Baseline is the `LND-8426` branch, not `main`.** The `manage_alias` parameter this runbook relies on (§4) is an LND-8426 addition (`ElasticSearch6Cache`, `local-glue-instructions.md:44-48`); trunk `kafka_to_adl.py` has no such flag and calls `_change_alias_and_remove_index` unconditionally. All `kafka_to_adl.py` line numbers below are **branch-relative** — don't diff them against `main`.
- **Pause the scheduled dev glue job** for the duration of the §5 window. It's not gated by `manage_alias`; if it fires while you hold the real `legal-leases` alias, its `_change_alias_and_remove_index` will repoint and can delete your swap-back index. Confirm it's idle before §5b.

## 1. Select test leases (SQL)

**Approach: control volume at the producer, not in the glue job.** Publishing exactly 1,000 mapped + 1,000 unmapped leases to a *fresh* test topic keeps the glue Kafka read fast (the original reason this run was slow) and lets us pin a known mapped `lease_id` for a deterministic clobber check — so the glue-side `.limit(1000)` caps are dropped (§3).

Run `query_2/sample-2000-split-leaseids.sql` on the CSTitle server. Outputs:
- **SET A / SET B** — the 1,000 mapped (df1) + 1,000 unmapped (df2) leases with `LeaseID`, `recordID`, `cstitle_county_id`, county/state (review/sanity).
- **FILE_LINES** — one `cstitle_county_id,recordID` per line, 2,000 rows. **This is the column you paste into the producer's `test_guids_8708.txt`.**
- **PINNED_MAPPED** — one mapped `LeaseID` to diff for the clobber check (§6). Record it.

Grain note: mapped leases can carry multiple mappings, so 1,000 mapped leases → **≥**1,000 df1 docs; 1,000 unmapped → exactly 1,000 df2 docs.

## 2. Publish to Kafka (land-lease-producer)

**Already wired on branch `LND-8708`** (revert before any merge). Applied edits:
- `land_lease_producer/main.py` → **CSTitle-only** (`[CSTitleLeaseDataProvider()]`), so the div1 provider doesn't publish beyond the 2,000 set.
- `cstitle_lease_data_provider.py` → a cached `load_test_guid_map()` reads `test_guids_8708.txt` into `{cstitle_county_id: [recordID,…]}`; `get_modified_instrument_ids(county_id, …)` returns **that county's** GUIDs (`.get(county_id, [])`).
- `land_lease_producer.py` `run()` → the county loop is gated to `test_county_ids = set(load_test_guid_map())`, i.e. **only the counties that hold the test leases**; each publishes its own record IDs. No arbitrary single-county hack.
- `kafka_producer.py` `_get_brokers()` → honors `KAFKA_BROKERS` (bypasses Consul SRV, which won't resolve in-container).
- `docker-compose.yml` → `KAFKA_BROKERS` = dev brokers + `OUTPUT_KAFKA_TOPIC=dp.pres.legalleases.v3_test_8708`.

**Your per-run steps:**
1. Paste the **FILE_LINES** column (`cstitle_county_id,recordID`) from `sample-2000-split-leaseids.sql` into `land_lease_producer/data_providers/cstitle_lease_data_provider/test_guids_8708.txt` (`#` lines ignored).
2. Put **fresh AWS session creds** in `docker-compose.yml` (the IIE enricher hits S3 — stale keys fail).
3. `docker-compose build && docker-compose up`. Expect `Initializing kafka producer to send N lease(s)` per test county, keys `lease::{LeaseID}`, to `dp.pres.legalleases.v3_test_8708`.

> The file is COPY'd into the image at build, so paste the lines **before** `docker-compose build`.

> Caveats: (a) processing the test counties mutates their dev CSTitle processing state (`set_county_as_currently_processed` / `update_last_processed_date`) — contained to those counties. (b) The `run()` lease-count/pending pass can pull a few *tract-related* mapped leases beyond the 2,000 (harmless — extra df1 only), so the published count may read slightly above 2,000.

## 3. The union-split edit (land-aws-glue) — the only pipeline change under test

In `jobs/kafka_to_adl/src/kafka_to_adl.py`, parameterize `filter_records_without_mapping_id`:

```python
@staticmethod
def filter_records_without_mapping_id(flat_df: DataFrame, include_unmapped: bool = False) -> DataFrame:
    df1 = flat_df.where(F.col("mapping_id").isNotNull())
    df1 = df1.groupBy("mapping_id").agg(
        *[F.first(f.name).alias(f.name) for f in flat_df.schema.fields if f.name != "mapping_id"])
    if not include_unmapped:
        return df1
    df2 = flat_df.where(F.col("mapping_id").isNull())
    df2 = df2.groupBy("lease_id").agg(
        *[F.first(f.name).alias(f.name) for f in flat_df.schema.fields if f.name != "lease_id"])
    # Washington-coast sentinel — the producer's own default point (land_lease_producer.py:53,
    # _generate_diamond(-129.134, 46.6723)). Stamping df2's location proves the sentinel behaves
    # (indexes cleanly, excluded from county searches) in the same run — see §7.
    WA_LON, WA_LAT = -129.134, 46.6723
    df2 = df2.withColumn("location", F.lit(f"{WA_LAT},{WA_LON}"))          # geo_point "lat,lon"
    df2 = df2.withColumn("location_shape", F.struct(                        # geo_shape point [lon,lat]
        F.lit("point").alias("type"),
        F.array(F.lit(WA_LON), F.lit(WA_LAT)).alias("coordinates")))
    return df1.unionByName(df2)
```

Callers: ES (line 721) and S3 (`create_legal_lease_dataframe`) pass `include_unmapped=True`; **DS9 keeps the default `False`** (byte-identical to today — the WA stamp only lives in the df2 branch, which `False` never builds). For the ES-only Dev run, only the ES caller needs `True`.

**No `.limit()` caps** — volume is controlled at the producer (§1–2, ~2,000 leases to a fresh topic), so the job runs unmodified beyond the union-split. This removes the earlier cap's two problems: the `legal-leases` swap window (§5) points at a real ~2,000-doc index rather than a truncated one, and the clobber check (§6) diffs a **pinned, deterministically-published** mapped `lease_id` instead of trusting non-deterministic `.limit()` survivors.

**Why stamp the WA sentinel here.** legal_lease `location`/`location_shape` are built from land-description lat/long (`kafka_to_adl.py:693-700`), which zero-mapping leases lack — so untouched they'd index **null**. Stamping df2 with the producer's existing WA point lets this one run answer both open questions: the docs emit *and* carry a sentinel location that a county search must exclude (§7). df1 is never touched, so mapped docs keep their real geometry.

> Keep the change behind the `include_unmapped` default so `include_unmapped=False` is provably the current behavior — the existing DS9 unit-test fixture (`tests/.../output_ds9_cache_legal_lease.json`) must stay green.

## 4. Run the job locally — `manage_alias=False` (applied on branch `LND-8708`)

The glue harness is on branch `LND-8708` (shelf `Local_Testing_` applied + the §3 union-split/WA-stamp edit). `run_job_locally()` builds only `ElasticSearch6Cache`. What's wired:

- **Consumes the fresh topic** `dp.pres.legalleases.v3_test_8708` (matches §2). The Kafka checkpoint starts from `earliest` on first run; if you re-run, clear the checkpoint dir (`/tmp/data/kafka_input_checkpoint`) so it re-reads the 2,000.
- **Index base `legal_lease_test`** → the job creates **`legal_lease_test_<ts>`** with the legal_lease mapping (`es_map/elastic_search_settings.json` — `location` `geo_point`, `location_shape` `geo_shape`). The base name is cosmetic; the mapping is the real legal_lease one. The manual swap (§5) points the **real `legal-leases`** alias at this index — the alias can target any index, so we don't rename the base.
- **`manage_alias=False`**. Load-bearing: with `False`, `update()` writes the new index and **stops** — it skips `_change_alias_and_remove_index` (`kafka_to_adl.py:654-656`), so it does **not** repoint any alias and does **not** delete the old index. The live `legal-leases` index stays intact as the swap-back target.

`docker-compose build && docker-compose up`. Note the created index from the log line `created new index - legal_lease_test_<ts>`.

> Why not `manage_alias=True`? It would repoint the alias for you **and delete the oldest matching index** (`_get_index_names` picks `sorted(available_indexes)[0]` as `index_to_remove` whenever ≥2 exist). With the usual 2 indexes that's your previously-live index — the auto-path deletes the very thing you need to swap back to. So the swap is done by hand in §5, deliberately without a delete.

## 5. Swap the alias (manual, no-delete), verify the consumer, swap back

The whole point of touching the real alias is Q3: prove the dev site doesn't break when null-`mapping_id` docs are behind `legal-leases`. Order matters — record the current target first so swap-back is unambiguous.

**a. Record the current live index** (this is your rollback target — do not delete it):
```
GET /_alias/legal-leases
```
**Write the `<old_ts>` index name down out-of-band** (not just in the terminal) — if your session dies mid-window, swap-back (§5d) is the *only* restore, and it needs this exact name.

**b. Cut over** — one atomic action, add new + remove old, **no index delete**:
```
POST /_aliases
{ "actions": [
    { "add":    { "index": "legal_lease_test_<new_ts>", "alias": "legal-leases" } },
    { "remove": { "index": "legal_lease_<old_ts>", "alias": "legal-leases" } }
] }
```

**c. Verify the consumer (Q3).** With df2 docs now live behind `legal-leases`, exercise the dev site / `legal_lease` consumers and confirm null-`mapping_id` docs don't break them — specifically anything that does `exists: mapping_id`, filters/sorts on `mapping_id`, or dedups one-doc-per-`mapping_id`. The index holds the ~2,000-lease test set, so the site shows that set during this window; that's expected — you're testing *behavior on null-`mapping_id` docs*, not data completeness. **Also eyeball the map:** the df2 docs should cluster at the WA-coast sentinel (§7), not scattered at county centroids.

**d. Swap back** — reverse action, restores the full live index instantly (it was never deleted):
```
POST /_aliases
{ "actions": [
    { "add":    { "index": "legal_lease_<old_ts>", "alias": "legal-leases" } },
    { "remove": { "index": "legal_lease_test_<new_ts>", "alias": "legal-leases" } }
] }
```

## 6. Capture results

**Field population (df2 doc)** — query the new index **by name** (independent of the alias state):
```
GET legal_lease_test_<new_ts>/_search   { "query": { "term": { "lease_id": <LeaseID> } } }
```
For each test lease, record populated vs absent against CLAUDE.md / SUMMARY.md:
- Populated: `lease_id`, grantor/grantee (+alias), `instrument_type`, `record_number`, `volume_page`, dates, `image_link`/`di_link`, county/state (+conformed), `api_*`, `state_id`/`county_id`; possibly `polygon_group_id`. **Plus `location`/`location_shape` = the WA sentinel** (`"46.6723,-129.134"` / point `[-129.134, 46.6723]`) — stamped in §3, *not* prod's default-null.
- Null: `mapping_id`, `abstract_id`, section/township/range (+dir), `survey_name`, `block_section`, `abstract_number`, `quarter_calls`, lat/long, `lease_count`(+symb). *(Note: prod-today would also null `location`/`location_shape`; this run overrides them — see §7.)*
- Confirm `record_id` and `geom_wkt` are not present (not in the ES projection).

**Clobber check (deterministic — no caps).** With volume controlled at the producer (§1–2), confirm:
- **empty intersection** — no `lease_id` appears in both the mapped (df1) and unmapped (df2) doc sets (`df1.lease_id ∩ df2.lease_id = ∅`). Load-bearing; structurally guaranteed by the coalesce.
- **mapped docs unchanged** — diff the **PINNED_MAPPED `lease_id`** from `sample-2000-split-leaseids.sql` (guaranteed published, so it appears in every run) field-by-field against an `include_unmapped=False` baseline run. Its `mapping_id`-grained doc(s) must be identical. df1 is untouched by the union-split and by the WA stamp (which only lives in the df2 branch), so this should hold exactly, not just on a spot-check.

## 7. Washington-coast sentinel (location for zero-mapping docs)

**This run tests the sentinel directly** — the §3 df2 stamp isn't optional scaffolding, it's the second thing under test. Stamping the WA point answers the location question empirically instead of deferring it to the team.

**The three location options for a zero-mapping doc:**
1. **Null (prod today).** legal_lease `location`/`location_shape` are built from land-description lat/long (`kafka_to_adl.py:693-700`); zero-mapping leases have no descriptions → both null. Cleanest *if* consumers tolerate a missing geo point (the doc just never matches a geo query).
2. **County center — rejected.** Every zero-mapping lease in a county collapses to one centroid, so a customer drawing/bbox-searching that county pulls in **all** of them — floods results with leases that have no real position. (TX alone = 53,085 zero-mapping leases.) The producer *already* stamps county-center into `geom_wkt` (`instruments.py:124` `enrich_by_default_county_center_location`), but that field isn't in the legal_lease projection — so this failure mode only appears if someone deliberately routes it to legal_lease location. Don't.
3. **Washington-coast sentinel — what we're testing.** A single deliberately-fake offshore point that matches no US county polygon (so county searches can't catch it) yet still renders on the US map (so un-located leases stay visible/diagnosable). This is **not classic Null Island (0,0)** — (0,0) is off West Africa, off-map for a US product. It's the producer's **own existing default**: `land_lease_producer.py:53` `_generate_diamond(-129.134, 46.6723)` — **lon −129.134, lat 46.6723**, in the Pacific off the WA/OR coast. Reusing the value already deployed upstream, not inventing one.
   - `location` (`geo_point`, `"lat,lon"`): `"46.6723,-129.134"`
   - `location_shape` (`geo_shape` point, GeoJSON `[lon,lat]`): `{ "type": "point", "coordinates": [-129.134, 46.6723] }`

**What the run proves (both questions, no team input needed to observe):**
- (Q3) the df2 docs emit and index cleanly into `legal_lease` with a populated geo point — no mapping-id dependency breaks them.
- (sentinel) run two geo queries against the new index:
  - a **county bbox** over any real county (e.g. a TX county the test leases belong to) → must return **zero** df2 docs (the sentinel is offshore WA, outside the polygon).
  - a **bbox around (46.6723, −129.134)** → must return the df2 docs.
  - Pass = the sentinel is searchable but invisible to county searches — exactly the county-center failure mode avoided.

**Still the team's to *ship*, not to *observe*.** This run gives the go/no-go evidence; the implementation ticket still decides null-vs-sentinel and confirms no consumer *requires* a non-null geo point (if some consumer needs "has location," the sentinel wins; if null is fine everywhere, null is cleaner). What's removed is the guesswork — we'll have measured behavior, not a coordinate someone made up.

## 8. What to write up

- Actual df2 docs (paste 1–2) with the field-population table, incl. `location`/`location_shape` = the WA sentinel (§7), and the note that prod-today would null them.
- Clobber-check result: empty intersection + PINNED_MAPPED doc identical to the `include_unmapped=False` baseline.
- Consumer verdict (§5c): did the dev site tolerate null-`mapping_id` docs behind `legal-leases`? This is the Q3 answer.
- **Sentinel verdict (§7):** county bbox returns 0 df2 docs; offshore-WA bbox returns them. Both questions answered in one run.
- Confirmation ES indexed the zero-mapping docs (doc count for the test lease_ids = number published).
- Feeds the go/no-go recommendation and the per-cache consequence table in SUMMARY.md.

## Revert

- **Alias:** swap-back is §5d (should already be done). Verify `GET /_alias/legal-leases` points at the original `<old_ts>` index. Optionally delete the scratch `legal_lease_test_<new_ts>` index and the `dp.pres.legalleases.v3_test_8708` topic once done.
- **Code:** discard the local branches — nothing merges. In glue, strip the WA-sentinel stamp on df2 (§3) — it's test-only, the *value* choice is the implementation ticket's. In the producer, strip the debug overrides (`main.py` CSTitle-only, hardcoded GUID list, county gate, `docker-compose` creds/topic) and the `run_job_locally` wiring. The union-split (`include_unmapped`) is the only change that carries into the implementation ticket.
