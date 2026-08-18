# LND-8674: Recent OH LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8674
**Status:** Backlog

Max Lease Date search for some OH counties showed max lease dates behind our most recent published leases.

Attached you will find a list of affected records that fall within the following counties:

- Cuyahoga, OH = 6 records
- Geauga, OH = 12 records
- Knox, OH = 7 records
- Lake, OH = 3 records
- Licking, OH = 4 records
- Medina, OH = 19 records
- Muskingum, OH = 2 records
- Portage, OH = 12 records
- Trumball, OH = 3 records
- Washington, OH = 5 records
- Wayne, OH = 1 record

## Attachment

`OH LegalLeaseNotPublished Records_07_20_2026.xlsx` (in this folder) — 75 rows, 17 columns.

Every row has `StatusDescription = Published` (`statusID = 4`) and populated `exportLogID`, `exportDate`, `Div1_LeaseID`, and `storageFilePath` — i.e. these leases were exported/published from the source system but are not reflected in the downstream max-lease-date search. Some `recordID`s appear on multiple rows (multiple `recordNumber`/image pages per lease).

Columns: `State`, `County`, `LseVol`, `recordID`, `RecdDate`, `statusID`, `StatusDescription`, `FileDate`, `recordNumber`, `instrumentTypeID`, `LeaseType`, `VolPg`, `exportLogID`, `exportDate`, `Div1_LeaseID`, `_ModifiedDateTime`, `storageFilePath`.

## Approach

**Scope:** read-only investigation into *why* these 56 records aren't publishing downstream. No fix, no backfill in this ticket.

**Framing:** the sheet's `exportDate`/`exportLogID`/`_ModifiedDateTime` come from `countyScansTitle.dbo.tblexportLog` (CHD plant record/image export) — not the land-lease-producer's Kafka publish. So the records are exported to the plant but absent from the downstream max-lease-date view. The break is in the lease publish path (land-lease-producer -> `dp.pres.legalleases.v3`), and `exportDate` spanning 2022-2026 rules out a single watermark gap — it's a systematic/repeating drop.

**Publish gates each record must pass (from land-lease-producer code):**
1. `StatusID in (4,10,16)`, `instrumentTypeID not in ('ASN','MD')`, `fileDate not null`, `tblexportLog.LeaseID not null` — `cstitle_get_modified_instrument_ids.sql`
2. **`INNER JOIN [Tracker].[MasterCountyLookup] mcl ON mcl.leasingID = C.Div1CountyID`** — `cstitle_get_instruments.sql:54`. Hard gate; unmapped county = record produces zero instrument rows, silently. **Top suspect.**
3. `CROSS APPLY tblexportLog ... LeaseID IS NOT NULL` — `cstitle_get_instruments.sql:55`. No lease-mapped export row = record dropped.
4. `instruments.lease_id.astype("int")` — `land_lease_producer.py:386`. Non-numeric leaseId fails the chunk.
5. County watermark `tblDataLoadersPerCounty.LastProcessedDateLandLeaseProducer` advanced past the record's modified time = never re-selected.

**Land descriptions / geometry are NOT hard gates** — they're LEFT-join enrichments; missing geometry falls back to a default "diamond" and the record still publishes. Cataloged for completeness only.

**Structural note (out of scope, but the recurrence mechanism):** the watermark advances on *send-attempted*, not *send-confirmed*. `produce_multiple` (kafka_producer.py:24-28) skips non-str messages with only a log; `_delivery_callback` (kafka_producer.py:77-79) logs delivery failures without retry/re-queue. Combined with the unconditional watermark advance at `land_lease_producer.py:166`, any record lost at send is orphaned permanently. Flag for a follow-up card.

**Landmine (unrelated to this bug):** `land_lease_producer.py:93-96` currently short-circuits all counties except a hardcoded `test_county_ids` set (`LND-8708 local test... Revert before merge`) — local uncommitted scaffolding; must not ship.

**Deliverable:** `query_1/diagnose.sql` — READ-ONLY, run on the CSTitle connection (`countyScansTitle`). Seeds the 56 `recordID`s into `#affected`, walks each through the gates in producer order, emits a per-record report with a `first_failed_gate` verdict + a headline rollup. Donald runs it in SSMS and returns results for interpretation.

## REFRAME (2026-08-11) — align with LND-8658 / LND-8426 investigation model

query_1 ran. Rollup: **53 `8_behind_watermark_orphaned`, 2 `5_no_exportlog_leaseid` (Summit NULL Div1_LeaseID), 1 `2_status_excluded` (Cuyahoga StatusID 17).** The `MasterCountyLookup` INNER JOIN (original top suspect) contributed **zero** — every OH county maps.

**But query_1 traced only the PRODUCER path, so `8_behind_watermark_orphaned` is a producer-side misattribution.** OH is in the StateID group (91/102/93) where `mapping_id` is minted ONLY by `div1_get_additional_fields.sql` from `tblleaseAbstractMapping`. The real failure class for this group (proven for WV in LND-8658, PA in LND-8426) is a **CONSUMER-side drop**: `land-aws-glue kafka_to_adl.filter_records_without_mapping_id` excludes any lease with null `mapping_id` (the DS9 document grain), so it never lands in DS9 `pres.legal_lease` nor ES `legal-leases`. The watermark is cause 3 (why they don't self-heal), not the original drop.

**Smoking gun already in query_1:** `has_land_description = 0` for ALL 56 records. No land description => no `tblAbstract`/`tblleaseAbstractMapping` => null `mapping_id` => consumer drop. query_2 confirms directly.

**Candidate causes, ranked (LND-8658 model):**
1. Zero-mapping -> dropped at DS9/ES consumer (`filter_records_without_mapping_id`). **Primary.** Test: `query_2` (mapping count in DIV1) + `query_3` (absent in DS9) + `query_4` (ES).
2. Producer exclusion: 2 Summit rows NULL Div1_LeaseID, 1 Cuyahoga StatusID 17. Never reach Kafka. Distinct cause; upstream data fix.
3. Watermark stranding (`LastProcessedDateLandLeaseProducer` at today): why the 53 won't self-heal even after a consumer fix — a normal incremental run never re-selects them. Needs forced re-publish. Secondary.

**Diagnostic order:** `query_2` (mapping count — decisive) -> `query_3` (DS9 absence) -> `query_4` (ES presence, run in Kibana). Expected outcome mirroring LND-8658: `mapping_count = 0` for the 49, ABSENT from DS9, likely ABSENT from ES too.

**Fix rec (out of scope; carry to LND-8658/8708 track):** mint a deterministic synthetic `mapping_id` for zero-mapping records so they publish without geometry (searchable, closes the max-lease-date gap; no map-render until real geometry). Plus forced re-publish to clear the watermark stranding. Same fix as LND-8658.

## Completed

- Workspace + CLAUDE.md created; GitHub link posted to Jira.
- Root-cause code trace of the producer publish path.
- `query_1/diagnose.sql` generated + run. Rollup: 53 orphaned / 2 no-leaseid / 1 status-excluded; county-mapping theory refuted.
- Reframed to LND-8658 consumer-drop model. Wrote `query_2/check_abstract_mapping.sql` (49 distinct LeaseIDs), `query_3/confirm_absence_ds9.sql`, `query_4/es_legal_leases_presence_check.json`.
- **CONFIRMED (2026-08-11): query_2 returned `mapping_count = 0` for ALL 49 distinct LeaseIDs.** Root cause = zero-mapping consumer drop, identical to LND-8658 (WV) / LND-8426 (PA). Not producer/watermark, not county mapping. The 53 orphaned OH records publish to Kafka but are dropped by `kafka_to_adl.filter_records_without_mapping_id` (null `mapping_id`) → absent from DS9 `pres.legal_lease` and ES `legal-leases`. **query_3 (2026-08-11): all 49 ABSENT from `[DS9].[pres].[legal_lease]` (0 rows each)** — sink confirmation. Diagnosis doubly confirmed. query_4 (2026-08-11): ES `legal-leases` terms query returned 0 hits (ABSENT from ES too → missing from both sinks, same as LND-8658). **Caveat:** 0 not yet controlled — add a known-published OH `lease_id` to the terms list to rule out a field/index mismatch before citing ES absence as firm. Does not affect the verdict (query_2 + query_3 are definitive).
- **Disposition:** fold into the LND-8708 mint-synthetic-`mapping_id` fix track (same fix as LND-8658). The 2 Summit NULL-LeaseID rows + 1 Cuyahoga StatusID-17 row are separate producer exclusions (upstream data), not part of the mint fix. Watermark stranding means the 53 need a forced re-publish after the fix — a normal incremental run won't re-select them.

## Completed

<!-- Updated as work is finished -->
