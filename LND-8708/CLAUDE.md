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

Cover both affected populations:

- **Zero-mapping leases** — no `tblLandDescription` and no abstract mapping anywhere; the lease is entirely absent from `legal_lease` today (e.g. LND-8426 record `4696618` / `a688f5be-8530-4647-b73d-089c185c8262`, COLUMBIA PA).
- **Partial-mapping leases** — some rows carry a `mapping_id`, some are null; the lease appears via its mapped rows while the null rows drop. Must be accounted for so the proposed change does not clobber leases that already publish correctly.

## Proposed approach under test (union-split)

Do not re-grain the existing path. Instead:

- **df1** — the current, untouched `groupBy("mapping_id")` path. Mapped leases stay byte-for-byte identical by construction.
- **df2** — leases with **zero** mappings anywhere, grained by `lease_id`, **excluding any** `lease_id` already present in df1 (so partial-mapping leases are not double-emitted as near-empty docs).
- Result = `unionByName(df1, df2)` (a union, not a key join).

The spike validates this shape produces the intended records and measures whether df1's document count for mapped leases is unchanged.

## Two measurements

1. **Source-side scope count (SQL).** Of the leases the producer published to Kafka (`tblexportLog.LeaseID` -> `tblRecord.recordID`), how many have zero abstract mapping in DIV1? Break out by state (expect PA/OH/WV heavy). Query attached (`unmapped-leases-scope-count.sql`) — single linked-server anti-join via `LinktoDiv1Repl`.
2. **Pipeline-side emission (Dev run).** Run the modified job in Dev against a real batch; capture the df2 records and field population.

## Targets

`filter_records_without_mapping_id` is inherited by `DS9Cache`, `S3Cache`, `DatabricksCache`, and `ElasticSearch6Cache`. Enumerate all four. **Live-test ES** `legal_lease` and DS9 in Dev (DS9 is where a NOT NULL / PK / FK on `mapping_id` will surface as an insert failure). S3 and Databricks covered as written analysis unless the DS9 result warrants live runs.

## Acceptance criteria

- Scope number: count of Kafka-published leases with zero abstract mapping, by state.
- Sample emitted docs: actual df2 records from a Dev run, enumerating which `legal_lease` fields are populated vs. null (expected null: `abstract_id`, `mapping_id`, section/township/range, `geom_wkt`; expected populated: `lease_id`, `record_id`, grantee, `image_link`, county/state).
- DS9 verdict: does the DS9 dev table accept a null-`mapping_id` row, or does a constraint reject it? Include the exact error if it fails.
- Per-cache consequence table: ES / DS9 / S3 / Databricks — tolerant or breaks, and why.
- Clobber check: confirm df1 document count for mapped leases is unchanged under the union-split.
- Recommendation for the implementation ticket: go/no-go per target + the union-split design.

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

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
