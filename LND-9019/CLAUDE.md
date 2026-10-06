# LND-9019: Orange County Enhanced Clerk – Legal Descriptions Not Publishing to Plant

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9019
**Status:** CANDIDATE FOR DEV

While ingesting plats into the **Orange County Enhanced Clerk** plant, we discovered that legal descriptions are not being published to the product.

As part of our investigation, we queried the **CS_Digital** database and confirmed that Orange County records do not contain legal descriptions in tbllandDescription. As a result, no legal descriptions are being published to the Enhanced Clerk plant.

However, the source index received from the clerk does contain legal descriptions, indicating that the legal data is being lost somewhere during the ingestion or transformation process before reaching CS_Digital.

**Request:**

- Investigate why legal descriptions from the source index are not being populated in CS_Digital.
- Determine where in the ingestion process the legal data is being dropped.
- Verify whether this issue affects only plat records or if other Orange County record types may be impacted.
- Provide a resolution to ensure legal descriptions are retained and published to the Enhanced Clerk plant.

**Business Impact:** Legal descriptions are a critical component of all Enverus products. Because the legal data is not making it into CS_Digital, the information is unavailable to customers in the final product, reducing the usefulness and completeness of the Orange County Enhanced Clerk plant.

## Approach

**Pipeline (4 stages, not 2)**
1. `digital-clerk-handler` — packages the raw clerk source index + images into a DIML package, dispatches the Nomad job. Does not parse legals.
2. `process-digital-clerk` — parses the index into a results JSON in DIML. Nests child records (parties, prior refs, locations) into arrays driven by manifest flags.
3. `diml-loaders/digitalclerk` — reads the results JSON from DIML, writes to the `clerk` staging schema SQL DB (`clerk.location`, etc.).
4. `cs-digital-mfg/clerk_load.py` — reads `new_locations`/`new_parties`/`new_records` from the `clerk` schema, writes `CS_Digital` (`TblLandDescription`, etc.).

**Root cause (confirmed end-to-end)**
- Child records nest into arrays only when a manifest column is flagged for that type: `"party": true`, `"prior_reference": true`, `"location": true`. `handle_dimensional_data(key='location')` collects only `"location": true` columns (`transformers.py:328`, `get_columns` `:30`).
- Orange County's manifest declares the clerk legal column as bare `{"name": "legal"}` with **no `"location": true` flag** (`ORANGE_TX/manifest.json:130`).
- Result: process-digital-clerk emits no `location[]` array for Orange; `legal` is a leftover flat scalar (`expected_output.json:15,66`). The diml loader reads land descriptions only from `record["location"][*]` (`digitalclerk_loader.py:77-85`), so nothing loads into `clerk.location`, and `clerk_load.py` inserts nothing into `TblLandDescription` (`clerk_load.py:197-198,274-277`). Parties/prior refs load because they are flagged.
- **Not plat-specific** — the gap is at the manifest-field level, so all Orange County record types lose their legal (answers ticket Q3).

**Candidate fix**
- Change the Orange manifest field from `{"name": "legal"}` to `{"name": "location.legal_description", "location": true}`, mirroring the party/prior_reference dotted-name + flag convention. This nests it into `location[].legal_description`, exactly the key the loader reads (`digitalclerk_loader.py:85`).

**Resolved**
- Production manifest lives in the DIML portal (app.drillinginfo.com/data/diml-portal/manifest), edited there — not deployed with the repo. Confirmed the live prod manifest has the same bare `{"name": "legal"}` with no `"location": true` flag. The repo `tests/integration_tests/ORANGE_TX/manifest.json` is a test copy of the same thing.
- `read_orange` (`readers.py:1460-1494`) is positional: it names columns directly from `manifest['columns']` order (`:1461,1470`) and only special-cases date composites. It does not interfere. Renaming the legal column makes the reader emit the new name, and `handle_dimensional_data(key='location')` nests it — same path `grantor.name`/`prior_reference.instrument_number` already take through this reader.

**Fix (validated)**
- In the diml-portal prod manifest, change the `legal` column from `{"name": "legal"}` to `{"location": true, "name": "location.legal_description"}`. Only that one column changes.
- Ready-to-paste corrected manifest: `query_1/orange_tx_manifest_fixed.json` (byte-identical to the live prod manifest except the one column).
- Sync the repo test manifest and regenerate `tests/integration_tests/ORANGE_TX/expected_output.json` so the integration test asserts the nested `location[].legal_description`.

**Cross-county sweep (repo test manifests)**
- Only 3 counties have a bare `"name": "legal"`: ORANGE, ROCKWALL, MIDLAND. The other 120 use `"location": true`.
- ROCKWALL: its `legal` carries `"location": true` — not broken.
- MIDLAND: `legal` is a subcolumn under a `location`-flagged parent — collected via the parent, likely fine.
- ORANGE: bare `legal`, no `"location"` flag, no other location-flagged columns — the only broken one.
- Caveat: repo test manifests can drift from live diml-portal copies. Authoritative cross-county check = query `CS_Digital.tbllandDescription` coverage per county (catches the gap regardless of manifest source).

**Backfill plan (decision: full historical backfill)**
Backfill correctness confirmed: `TblRecord.update` soft-deletes all child records (`IsDeleted=1`) and re-inserts them (`models.py:382-383,444-451`; `TblLandDescription.update`→`insert` `:243-246`). So reprocessing existing Orange records as updates replaces their empty land descriptions with corrected ones. Chain:
1. Re-run `process-digital-clerk` on each historical Orange raw package (preserved `source_index` in DIML) WITH the fixed manifest → regenerates results JSON with nested `location[].legal_description`. (Re-running only the diml loader on the OLD results won't work — old results carry flat `legal`, no `location[]`.)
2. The diml loader skips packages whose parent is already in `clerk.instrument` (`digitalclerk_loader.py:161-163`). So the Orange `clerk`-schema rows must be cleared first (clerk.instrument/location/party/prior_reference for the Orange `parent_package_id`s) so the new results re-ingest. This is a destructive op on the staging DB — run manually, not scripted here.
3. `clerk_load.py` matches existing CS_Digital records as updates → soft-deletes old empty land descriptions, inserts corrected ones (`tblLandDescription`).

Sizing query: `query_1/orange_history_depth.sql` (counts batches/packages/records + date range in `clerk.instrument` for ORANGE_TX). `batch_count` = number of process-digital-clerk re-runs required.

**Backfill execution steps (verified against code)**
Ordering matters — each stage feeds the next.

0. Prereq: apply the diml-portal manifest fix FIRST. `process-digital-clerk` fetches the manifest live per run (`main.py:345` `source["manifest"]`, via `get_source` `:280-306`), so every reprocess picks up the corrected manifest automatically. The manifest is not baked into old results.

1. Enumerate raw packages: distinct `parent_package_id` from `clerk.instrument` WHERE `diml_county_name='ORANGE_TX'` (from the sizing query). That value IS the raw-data package id `process-digital-clerk` downloads (diml-loaders sets it, `digitalclerk_loader.py:160`). One reprocess per package.

2. Reprocess each raw package: dispatch the `process_digital_clerk_job` parameterized Nomad batch job once per package. Only two values vary per dispatch — the Nomad meta `package_id` and `source_group` — mapped to env by consul (`consul-kv/services/process-digital-clerk.yaml`: `RAW_DATA_PACKAGE_ID=${NOMAD_META_PACKAGE_ID}`, `RAW_DATA_SOURCE_GROUP=${NOMAD_META_SOURCE_GROUP}`). `DIGITAL_CLERK_SOURCE_ID` and `RESULTS_PACKAGE_ID` are STATIC in consul — `RESULTS_PACKAGE_ID` is one shared datalake package every run appends a results dataset to; nothing is minted per run. The driver just POSTs the Nomad dispatch with `Meta={package_id:<raw pkg>, source_group:"ORANGE_TX"}` per package — identical to the handler's `start_diml_job` (`process_digital_clerk.py:169-176`). The container downloads the preserved `source_index`, re-parses with the live (fixed) manifest, uploads a fresh `results` JSON with `location[].legal_description` (`main.py:388,395,182`). Long pole — `batch_count` dispatches; needs a loop.

3. Clear Orange clerk-schema staging rows: the diml loader skips packages whose `parent_package_id` already exists in `clerk.instrument` (`digitalclerk_loader.py:161-163`). Delete the Orange rows from `clerk.instrument` + children `clerk.location`/`clerk.party`/`clerk.prior_reference` for those `parent_package_id`s so re-ingest happens. Destructive op on the staging DB — run manually. CS_Digital is untouched.

4. Re-ingest: run diml-loaders digitalclerk (or let the scheduled run fire). It finds the new `results` datasets in its date window; the guard now passes; it writes fresh `clerk.location` rows with `legal_description` populated.

5. clerk_load backfill for Orange: use the ad-hoc path (`cs-digital-mfg/main.py:98-106`). Set `COUNTY=ORANGE_TX` (`:32-36`), explicit `START_DATE`/`END_DATE` over the re-ingest window, `backfill=True` so `LastLoadDate` is not advanced (`:104-105`, `clerk_load.py:315-316`). Existing records classify as updates → `TblRecord.update` soft-deletes child land descriptions and re-inserts them (`models.py:382-383,444-451`; `TblLandDescription.update`→`insert` `:243-246`). Empty legals replaced with real ones.

6. Validate: per-county `tblLandDescription` coverage for Orange before/after (records with vs. without a non-deleted land description), plus end-to-end spot checks.

Execution notes:
- `clerk_load` re-runs image handling per record in the window (`clerk_load.py:246-260`); batch the backfill by date window (e.g. month by month) to keep transactions + image work manageable and to checkpoint.
- Steps 2 and 3 are independent (can run in parallel) but both must complete before step 4.

**Local pre-check (done, passed)**
`query_1/verify_manifest_local.py` runs the real `process_index.process_index_file` (from `C:\Users\donald.massey\PycharmProjects\process-digital-clerk`) on the Orange test data twice: baseline = `orange_tx_manifest_fixed.json` with only the legal column reverted to bare `{"name": "legal"}`; fixed = the file as-is. Result: 1153 records both, 1151 records gain `location[].legal_description`, flat `legal` gone, zero diffs outside `legal`/`location`, all legal text identical. Run: `cd process-digital-clerk && python -W ignore ../jira-repos/LND-9019/query_1/verify_manifest_local.py`.
- Gotcha: repo test manifest differs from live prod (`has_footer` false vs true, `image_path_format`). Always baseline against the prod-derived manifest, not the repo copy — `has_footer: true` drops the last line and looks like a lost record.
- Script stubs pdfquery/xlrd/dask/pdfplumber/diml_* (unused for index parsing) and shims `DataFrame.append` for pandas 2.x. It covers process-digital-clerk only, not the loader or `clerk_load`.

**Dev test flow (verify before prod)**
Corrected dev manifest (byte-identical to live dev except the one column): `query_1/orange_tx_manifest_fixed_dev.json`. Each numbered gate must pass before the next stage. Do not edit the prod manifest until all gates pass in dev — a manifest edit applies to every future Orange run immediately (no deploy step).
1. Baseline (before any change): run `query_1/step2_pick_dev_orange_package.sql` (dev clerk staging DB), take the smallest `parent_package_id`. Pick 2–3 instruments from it; record instrument number + source legal (raw `source_index` in DIML, or flat `legal` in the old results JSON). Record current `CS_Digital.tblLandDescription` non-deleted row count and `tblRecord.propertyDescription` for them (expect 0 rows / empty), plus `clerk.party`/`clerk.prior_reference` row counts.
2. Apply `orange_tx_manifest_fixed_dev.json` to the ORANGE_TX source in the DEV diml-portal.
3. Clear that package's dev clerk rows so the loader re-ingests (`digitalclerk_loader.py:161-163`). Identify with `query_1/step3_clerk_cleanup_identify.sql` (SELECT only); delete manually, children first (`clerk.location`/`party`/`prior_reference`, then `clerk.instrument`). Dev staging only; CS_Digital untouched.
4. Reprocess: dispatch `process_digital_clerk_job` in dev with `Meta={package_id:<parent_package_id>, source_group:"ORANGE_TX"}`.
   - Gate 1: new `results` dataset in DIML has `location[].legal_description` for the chosen instruments and no flat `legal`. Fail => manifest edit didn't take (check dev ORANGE_TX source has the new column and the job fetched it).
5. Let diml-loaders (dev) digitalclerk ingest the new results.
   - Gate 2: `SELECT * FROM clerk.location WHERE instrument_id IN (...)` shows `legal_description` matching the source text; `clerk.party`/`clerk.prior_reference` counts equal baseline. Fail => package-skip guard fired (step 3 rows not cleared).
6. Run clerk_load (dev) for Orange. DEV dispatch path (no local Docker needed): the `courthouse_mfg` Airflow DAG's `csdigital_mfg_nomad` task → Nomad job `cs_digital_mfg_job` (region `azure-hci-ash`, Vault-injected DB creds). Set `meta_csdigital_mfg = {county: ORANGE_TX, start_date, end_date, iie_start_date, iie_end_date}` and run ONLY that task (ignore upstream/downstream) — a full DAG run also fires the diml loaders, the Databricks `queue_llandman` extraction, and the cstitle sync. `START_DATE`/`END_DATE` are matched against `clerk.instrument._CreatedDateTime` (the re-ingest timestamp, i.e. recent), NOT the historical file dates. Set the iie window to a no-op (start==end) so the clerk container's internal `load_iie` does nothing.
   - **backfill reality:** the deployed image hardcodes `backfill=False` (`main.py:105`); there is no `backfill` meta param. So the run advances Orange's `LastLoadDate` to `end_date`. Keep `end_date`≈today so the next scheduled run doesn't skip a gap. (Local-only: `main.py:105` can be edited to `True`.)
   - Gate 3: dev `CS_Digital.tblLandDescription` has non-deleted rows for those records (verify text in `TractDescription`, see below); grantor/grantee ACTIVE (`IsDeleted=0`) counts equal baseline and the originals are retired (`IsDeleted=1`); prior refs intact. Queries: `query_1/step6_gate3_verify_cs_digital.sql` + `query_1/step6b_gate3_confirm_content.sql`. Fail => check `COUNTY` and date window.
   - **Where the legal lands:** `format_locations` concatenates `legal_description` (+ subdivision/survey/section/…) into `brief_legal`, which maps to `tblLandDescription.TractDescription`. That is the publish path. `tblRecord.propertyDescription` stays NULL — a pre-existing index-misalignment bug at `clerk_load.py:206-208` (a `groupby` Series keyed by `instrument_id` is assigned onto a reset-index `headers` → all NaN). Affects every county, out of scope for LND-9019. Do NOT treat empty `propertyDescription` as a failure.
7. Spot-check 2–3 instruments end to end (source index legal → `clerk.location.legal_description` → `tblLandDescription.TractDescription` → dev Enhanced Clerk plant). The plant is the only check of the publish side; verify at least one record there. **Gated on the overnight publish:** the CH3.0 / Enhanced Clerk plant only reflects the new `tblLandDescription` rows after `courthouse-land-data-loader` runs overnight. clerk_load writing CS_Digital does NOT update the plant immediately — wait for the next CHLDL cycle, then check.
Scope note: this is a diml-portal manifest edit, not a consul-kv or secret change, so the consul-kv/MyGlue deploy checks don't apply — nothing new to store.

**DEV validation result (PASSED, 2026-10-06)**
Package `cqlarqtnpr4g00a1e6f0` (Orange May 2024, 1,036 instruments), test instruments 542741–542752.
- Gate 1: reprocessed results have `location[].legal_description`, no flat `legal`; parties 4,516, prior refs 0.
- Gate 2: `clerk.location` = 1,032 rows all with `legal_description`; parties 4,516, prior refs 0 (baseline unchanged).
- Gate 3: `tblLandDescription` non-deleted rows for all 12 with the legal text in `TractDescription` (matches Gate 2 exactly); whole-month coverage 0 → 1,032; grantor/grantee active counts == baseline, originals `IsDeleted=1` (no dups); `propertyDescription` NULL as expected.
- Remaining: plant spot-check (publish side) — gated on the overnight `courthouse-land-data-loader` run.

**Open items**
- Plant spot-check in DEV: confirm one re-loaded Orange record now shows its legal in the Enhanced Clerk plant (publish side).
- Run `orange_history_depth.sql` to size the backfill before executing.
- Confirm how process-digital-clerk is re-dispatched per historical package (Nomad dispatch with `RAW_DATA_PACKAGE_ID`, same path as `start_diml_job`) and whether a batch/backfill driver exists or needs writing.
- clerk_load re-dispatch in prod is the same shape: `cs_digital_mfg_job` Nomad job (prod datacenter `vmw-ash`), `backfill=False` deployed → `LastLoadDate` advances; keep `end_date`≈now.
- Confirm the exact `clerk`-schema cleanup scope (OK to delete all Orange staging rows; CS_Digital records are preserved and only updated).
- MIDLAND: quick confirm its nested `legal` subcolumn actually loads (low priority; not the reported defect).

## Completed

<!-- Updated as work is finished -->
