# LND-8658: Recent WV LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8658
**Status:** CANDIDATE FOR DEV

Max Lease Date search for some WV counties showed max lease dates behind our most recent published leases.

Attached you will find a list of affected records that fall within the following counties:

- Braxton, WV = 2 records
- Preston, WV = 5 records
- Randolph, WV = 6 records
- Upshur, WV = 2 records

## Approach

**Type:** Diagnosis. Determine *why* the 15 WV records never published to `dp.pres.legalleases.v3`
(and its ES / DS9 caches), then state whether a fix exists. Not committed to implementing a fix.

**Affected set:** 15 export-log rows in `WV LegalLeaseNotPublished Records_07_16_2026.xlsx`
(Downloads), collapsing to 11 distinct `recordID`s across Braxton/Preston/Randolph/Upshur. Each
row is `StatusID=4 (Published)`, has an `exportLogID`/`exportDate`, and a `Div1_LeaseID` except
Randolph `7c1984cb-341d-43ca-aabf-46ea6b04531c` (null). Publish key downstream is
`lease::{lease_id}` where `lease_id = tblexportLog.LeaseID = Div1 LeaseID`.

**LEADING HYPOTHESIS — same root cause as LND-8426 (Recent PA LegalLeases Not Published):
zero-mapping leases dropped at the consumer.** The producer publishes these to Kafka fine (they
have exportLog rows). The consumer `land-aws-glue` job `kafka_to_adl.py` drops them at
`filter_records_without_mapping_id`: a lease with no `tblleaseAbstractMapping` entry in DIV1 has a
null `mapping_id`, and `mapping_id` is the document grain (`groupBy("mapping_id").agg(first)`), so
it is excluded from the DS9 `pres.legal_lease` cache. The LND-8426 spike draft predicts
"PA/OH/**WV** heavy." ES was patched to keep unmapped leases (LND-8708 union-split, `include_unmapped=True`,
`kafka_to_adl.py` line 741); **DS9 was NOT** — so these WV leases stay invisible in DS9 every run
(the full-cache mirror keeps them, but each DS9 write re-drops them).

**Candidate causes, ranked:**
1. Zero-mapping -> dropped at DS9 consumer (`kafka_to_adl.filter_records_without_mapping_id`).
   Primary. Test: `query_3` (mapping count in DIV1) + `query_2` (absent in DS9, maybe present in ES).
2. Producer filter exclusion: `cstitle_get_modified_instrument_ids.sql` requires `el.leaseId IS NOT
   NULL`. Randolph `7c1984cb` has no Div1 LeaseID -> never reaches Kafka. Distinct cause; needs its
   own handling (fix upstream data, not the consumer).
3. Stranded behind the per-county watermark: `land_lease_producer.run()` advances
   `LastProcessedDateLandLeaseProducer` unconditionally (orchestrator line 166); a record missed once
   is never re-selected. Secondary. Test: `query_1`.

**Key sink facts (from land-aws-glue kafka_to_adl):** DS9 table `pres.legal_lease` (grain =
mapping_id, keyed lease_id); ES index base `legal_lease` / alias `legal-leases`; Kafka topic
`dp.pres.legalleases.v3_2024_04_23`; producer primary key `lease_id`, partition size 100000.

**Causal chain (why WV zero-mapping = not published):** image -> parsed land description
(BriefLegal/abstract) -> `tblAbstract` + `tblleaseAbstractMapping` -> `mapping_id` on the Kafka
message -> survives the consumer's mapping filter. For WV, `mapping_id` is produced ONLY by
`div1_get_additional_fields.sql` (`WHERE a.StateID in (91,102,93)`), which reads
`tblleaseAbstractMapping`. `div1_get_land_descriptions.sql` explicitly EXCLUDES WV/OH/PA
(`StateID not in (91,102,93)`) and `cstitle_get_land_descriptions.sql` carries no mapping id at all.
So a WV lease with no abstract-mapping row has null `mapping_id` everywhere and is dropped at DS9.
Two of the 15 (Preston `141ae74f`, `5635d98f`) have `storageFilePath = NONE` — no image to parse
into a mapping in the first place.

**Diagnostic steps (run in this order):**
1. `query_4/evaluate_images_landdesc_pipeline.sql` (TOP) — per record: image presence
   (`tblDimlXref`), CSTitle land-description rows (`tbllandDescription`), DIV1 abstract-mapping count,
   and a pipeline verdict (excluded-at-producer / dropped-at-DS9 / should-publish). One query answers
   "do these have land descriptions + images, and where do they stop."
2. `query_3/check_abstract_mapping.sql` — focused mapping count for the 10 LeaseIDs (redundant with
   query_4's mapping column; keep as a clean confirmation).
3. `query_2/confirm_absence_ds9.sql` — confirm ABSENT in `pres.legal_lease` (+ ES cross-check;
   present-in-ES/absent-in-DS9 pins it to "DS9 not yet union-split").
4. `query_1/diagnose_selection_eligibility.sql` — only for any lease that comes back mapped
   (rules in/out watermark stranding + confirms the Randolph null-leaseId exclusion).

**CONFIRMED (2026-08-11) — root cause is cause 1 for all 10 mapped candidates.** Diagnostic chain
closed: query_1 (all 10 pass every producer static filter + carry real exportLogIDs -> reached
Kafka) -> query_3 (`mapping_count = 0` in DIV1 for all 10 -> null `mapping_id`) -> query_2 (all 10
ABSENT from `[DS9].[pres].[legal_lease]`, 0 rows each). So they publish to the topic and are dropped
by the consumer's `filter_records_without_mapping_id`. Randolph `7c1984cb` is cause 2 (no Div1
LeaseID; excluded at the producer, never reaches Kafka).

**ES cross-check overturned the "ES patched, DS9 not" framing.** The affected 10 are ABSENT from ES
too (`legal-leases` terms query = 0 hits; field name verified via control lease 5027303 which
returns cleanly, so not an artifact). This is the firm finding: the 10 are missing from BOTH sinks.

Attempted tiebreaker `must_not exists mapping_id` returned **0**, but it is NOT conclusive: it finds
only null/absent-`mapping_id` docs, and if the LND-8708 split mints a synthetic `mapping_id` (exactly
the approach we favor), unmapped-origin docs would carry a non-null id and this check returns 0 even
with the split live. So "0 unmapped docs" is consistent with BOTH "split not live" AND "split live
but mints ids." Whether LND-8708 is in prod is therefore still open (confirm from deploy state /
`land-aws-glue` release, not from ES field presence). Does not change the core diagnosis.

**Watermark (cause 3) is not the original cause but IS why they won't self-heal.** They already
exported once, so stranding didn't cause the first drop. But county watermarks sit at today
(query_1) and these records exported 2018-2026, so a normal incremental run never re-selects them
-> they never re-flow through Kafka -> a future union-split/mint fix won't reach them without a
forced re-publish.

**Fix (revised — mint a synthetic mapping_id, do NOT publish a null).** The ES-style
`include_unmapped=True` union-split alone dies on DS9: `mapping_id` is the document grain and key, so
a null row can't land in `pres.legal_lease`. The fix is to **mint a deterministic synthetic
`mapping_id`** for records that have none, so they publish as a document row **without geometry**.
This is consistent with the geometry model (geometry is mapping_id-grained via sibling-save; a minted
mapping with no abstract/SVG simply carries no point/polygon) — the record becomes searchable and the
max-lease-date gap closes; it just won't map-render until real geometry exists. Acceptable tradeoff,
directly addresses the customer complaint. This also retires the old null-constraint go/no-go gate:
we never send null.

Design constraints before implementing:
- **Deterministic + collision-free.** Same lease -> same minted id on every run (else dupes/churn),
  and provably disjoint from real `tblleaseAbstractMapping` ids (reserved namespace, e.g. offset or
  negative range derived from `lease_id`).
- **Where minted:** leaning producer-side (emit the synthetic id on the Kafka message) so ES and DS9
  get the same id rather than diverging; consumer-side (inside the DS9 union-split) is the alternative
  and keeps it colocated with the LND-8708 ES change.
- Randolph `7c1984cb` (cause 2) is a separate upstream data fix (assign a Div1 LeaseID), not covered
  by the mint-a-mapping change.

**Constraints:**
- Query execution: I write `.sql`, user runs in SSMS and pastes results.
- `query_3`/`query_2` LeaseID lists cover 10 leases; the 11th record (Randolph `7c1984cb`) has no
  Div1 LeaseID and is handled as cause 2.
- Working tree of `land-lease-producer` is dirty with active LND-8708 test hacks (orchestrator lines
  18, 86, 94-96); `land-aws-glue` `kafka_to_adl.py` also carries live LND-8708 edits. Any LND-8658
  code work must start from a clean branch.
- HARD RULE: no destructive statements (`UPDATE`/`DELETE`) in `.sql` files.

## Related tickets
- **LND-8426** — Recent PA LegalLeases Not Published (parent investigation; same failure class).
- **LND-8708** — union-split so ES publishes zero-mapping leases (`include_unmapped=True`). DS9 not
  yet covered.
- Spike draft: `land-aws-glue/LND-8426-unmapped-leases-spike-DRAFT.md`; source checks:
  `land-aws-glue/LND-8426-pa-mapping-checks.sql`, `LND-8426-unmapped-leases-scope-count.sql`.

## Completed

- Parsed affected xlsx: 15 export-log rows, 11 distinct recordIDs, 10 distinct non-null Div1
  LeaseIDs (Randolph `7c1984cb` has none). All `StatusID=4`, valid instrument types, non-null fileDate.
- Traced the full path producer -> Kafka -> `kafka_to_adl` consumer -> DS9/ES/S3/Databricks caches.
- Identified the consumer's `filter_records_without_mapping_id` drop and matched it to the existing
  LND-8426/LND-8708 work (WV explicitly called out as an expected affected state).
- Pinned sink names: DS9 `pres.legal_lease`, ES `legal_lease`/`legal-leases`.
- Traced the WV mapping_id mechanism: only `div1_get_additional_fields.sql` (StateID 91/102/93)
  emits it, from `tblleaseAbstractMapping`; WV excluded from the standard land-description path.
- Wrote (all read-only): `query_4/evaluate_images_landdesc_pipeline.sql` (TOP — images + land
  descriptions + mapping + verdict), `query_3/check_abstract_mapping.sql`,
  `query_2/confirm_absence_ds9.sql` (now fully qualified `[DS9].[pres].[legal_lease]`),
  `query_1/diagnose_selection_eligibility.sql`.
- Ran query_1, query_2, query_3 in SSMS. Results confirm cause 1 for all 10 mapped candidates and
  cause 2 for Randolph `7c1984cb` (see CONFIRMED block above).
- Revised fix rec from "null union-split" to "mint a synthetic mapping_id, publish without geometry."

## Awaiting
- ES cross-check (user runs the DSL terms query against `legal-leases`; no ES access from this
  session). Expect the 10 PRESENT in ES + ABSENT in DS9 -> demonstrates the LND-8708 asymmetry
  (ES union-split applied, DS9 not). Evidence only; does not change the confirmed root cause.
- Post diagnosis + fix rec comment on LND-8658.
