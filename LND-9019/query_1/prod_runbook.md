# LND-9019 Prod Runbook: Orange County legal descriptions

Orange County Enhanced Clerk records have no legal descriptions in `CS_Digital.tblLandDescription` because the Orange manifest column `legal` has no `"location": true` flag. `process-digital-clerk` therefore emits no `location[]` array, and nothing reaches `clerk.location` or `tblLandDescription`.

**Status:** DEV-VALIDATED (2026-10-06), plant spot-check pending. Gates 1–3 passed end-to-end in DEV on package `cqlarqtnpr4g00a1e6f0`: reprocessed results carry `location[].legal_description`; `clerk.location` loaded 1,032 rows with legal; `tblLandDescription` got non-deleted rows with the legal in `TractDescription`; grantor/grantee active counts unchanged, originals soft-deleted (no dups). Do not start prod until the DEV plant spot-check confirms the publish side.

## 0. Prerequisites

- DEV Gates 2 and 3 pass, plus a plant spot-check of 2-3 instruments.
- Run `orange_history_depth.sql` in prod. `batch_count` is the number of raw packages (`parent_package_id`) to reprocess. Record the date range.
- Prod AWS credentials are available for the reprocess. Do not mix DEV and PROD credentials.
- Baseline captured: Orange `tblLandDescription` coverage per month, and `clerk.party` / `clerk.prior_reference` counts per package.

## 1. Back up the current prod manifest

In the diml-portal (app.drillinginfo.com/data/diml-portal/manifest), copy the live ORANGE_TX manifest to `query_1/orange_tx_manifest_prod_before.json`. This is the rollback.

## 2. Clear Orange staging rows first, before reprocessing

In prod the reprocessed package is the same `parent_package_id` already in `clerk.instrument`. The loader skips packages already present (`digitalclerk_loader.py:161-163`). If the scheduled loader runs between the reprocess and the cleanup, it skips the new results and its date window moves on, so they never load. Clear first.

- Identify the rows with `step3_clerk_cleanup_identify.sql` (parameterised by `@parent_package_id`).
- Delete children first (`clerk.location`, `clerk.party`, `clerk.prior_reference`), then `clerk.instrument`.
- Run manually, in a transaction, and verify row counts against the identify query before committing. In DEV, ~5,500 rows took 22 minutes, so batch the prod deletes.
- `CS_Digital` is not touched.

## 3. Apply the manifest fix in the prod portal

Change only the legal column:

```
from: {"name": "legal"}
to:   {"location": true, "name": "location.legal_description"}
```

Ready-to-paste file: `query_1/orange_tx_manifest_fixed.json`. The edit applies to every future Orange run immediately; there is no deploy step.

## 4a. Note on start/end dates for clerk_load (step 6)

`clerk_load` selects `clerk.instrument` by **`_CreatedDateTime`** (staging re-ingest time), not the historical file date. So the step-6 `start_date`/`end_date` must bracket **when the re-ingest happened** (recent), not the 2024 document dates.

## 4. Reprocess each raw package

One run per `parent_package_id` from the sizing query.

| Setting | Value |
|---|---|
| `RAW_DATA_PACKAGE_ID` | the raw package id |
| `RAW_DATA_SOURCE_GROUP` | `ORANGE_TX` |
| `DIGITAL_CLERK_SOURCE_ID` | `b4oreu0nqpr01f10mr5g` |
| `RESULTS_PACKAGE_ID` | `b7n5f2tqq0g01f2t9j90` |
| `DIML_BASE_URL` | `app-a-in.drillinginfo.com/diml-core` |

- Normal route: dispatch the Nomad `process_digital_clerk_job` (region `vmw-ash`) with `Meta={package_id: <raw package>, source_group: "ORANGE_TX"}`. Needs someone with prod Nomad access.
- In DEV one package of 1,036 instruments took about 2 minutes.
- After each run, confirm the new results dataset has `location[].legal_description` and no flat `legal`. `verify_gate1_results.py` does this (set `DATASET_ID`).

## 5. Re-ingest

The prod diml-loaders digitalclerk loader picks up the new `results` datasets on its schedule. Confirm:

- `clerk.location` has rows with `legal_description` populated.
- `clerk.party` and `clerk.prior_reference` counts equal the baseline.

## 6. Backfill CS_Digital with clerk_load

- Dispatch the `cs_digital_mfg_job` Nomad job (prod datacenter `vmw-ash`) — the `courthouse_mfg` DAG's `csdigital_mfg_nomad` task. Run ONLY that task (ignore upstream/downstream); a full DAG run also fires the diml loaders, the Databricks `queue_llandman` extraction, and the cstitle sync. Meta: `{county: ORANGE_TX, start_date, end_date, iie_start_date, iie_end_date}` with a no-op iie window (start==end).
- `start_date`/`end_date` = the `_CreatedDateTime` re-ingest window (see 4a), not the file dates.
- **backfill:** the deployed image hardcodes `backfill=False` (`main.py:105`) — no meta toggle. The run WILL advance Orange's `LastLoadDate` to `end_date`. Keep `end_date`≈now so the next scheduled run doesn't skip a gap. (To preserve the watermark you'd need a code change; not available via the standard job.)
- Batch month by month over the re-ingest windows. clerk_load re-handles images per record, so small windows keep transactions manageable and give checkpoints.
- Existing records classify as updates: `TblRecord.update` soft-deletes ALL child rows (`_delete_child_records`, `models.py:460-466`: land descriptions, grantor/grantee, deed refs → `IsDeleted=1`) and re-inserts them. Orange had no land descriptions before, so those are net-new; grantor/grantee originals are retired and re-inserted (active count unchanged).

## 7. Validate

- Per-month Orange `tblLandDescription` coverage before and after (non-deleted rows; the legal text lands in `TractDescription`).
- Grantor/grantee ACTIVE (`IsDeleted=0`) counts unchanged; originals retired (`IsDeleted=1`). Count without an `IsDeleted` filter and you'll see ~2x (active + retired) — that is not a duplicate.
- Do NOT check `tblRecord.propertyDescription` — it stays NULL (pre-existing `clerk_load.py:206-208` index-misalignment, all counties; legal publishes via `tblLandDescription.TractDescription`).
- Spot-check at least one record in the Enhanced Clerk plant. **Gated on the overnight publish:** the CH3.0 / Enhanced Clerk plant only reflects the new `tblLandDescription` rows after `courthouse-land-data-loader` runs overnight — clerk_load writing CS_Digital does not update the plant immediately. Wait for the next CHLDL cycle, then check.
- Queries: `step6_gate3_verify_cs_digital.sql`, `step6b_gate3_confirm_content.sql`.

## Rollback

Revert the manifest from step 1. The old land descriptions were empty, so the soft-deletes lose nothing.

## Notes

- This is a portal manifest edit plus data reprocessing. No new consul-kv entries or secrets, so the consul-kv and MyGlue deploy checks do not apply.
- Only Orange had a bare `legal` column among the repo test manifests, but repo manifests can drift from the portal. The authoritative cross-county check is `CS_Digital.tbllandDescription` coverage per county.
