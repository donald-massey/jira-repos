# landtrac-unit-pipeline-map — Removing DIV1 from the Landtrac Unit Pipeline

Design/decision workspace for **offlining the DIV1 dependency** in the GIS landtrac-unit
pipeline. Spun out of **LND-8911** (tblDaapUnit froze 2026-07-14). This repo holds the
architecture map (V001 = current DIV1 dependencies, V002 = DIV1 loop closed) and the decision
set the GIS + Land Data teams must settle before cutover. It is documentation, not code.

**North star:** DIV1 → Databricks Unity Catalog migration. This workspace covers the **GIS-team
slice only** — other DIV1 consumers own their own migration.

**Wells re-key decision (GIS + Land, with Lindsey Chambers, 2026-09-09):** do **not** depend on
DIV1 `WellID` or `daapUnitID`. Re-key the pipeline on **UWI 12/14** and source wells from
`enverus.data.foundations_wells` (the canonical Enverus wells product), not a UC mirror of the
DIV1 tables. This one table also collapses the 5 DIV1 lookup joins (State/County/Abstract/
WellStatus/Company). See `OFFLINING-DECISIONS.md` → "Strategic pivot" and D5a.

## Files

- `CONTEXT.md` — scope, glossary, blast radius, D1/D2 open decisions (grill-with-docs seed).
- `OFFLINING-DECISIONS.md` — the authoritative decision doc: DIV1 table footprint, UC
  availability blocker, D1–D6, and the pre-commit advisory summary. **Start here.**
- `NEW-PIPELINE-V001.md` / `NEW-PIPELINE-V001.html` — holistic target-pipeline draft: every
  D1–D6/D5a decision resolved to a **recommended** value (with team **options** beside each) so the
  end-state reads as one coherent design. Presentation companion to `OFFLINING-DECISIONS.md`. D5a
  recommended = UWI on a new `v4` topic, `v3` in parallel until consumers drain.
- `index.html` / `landtrac-unit-pipeline.drawio` — top-level map.
- `v001/` — current-state diagram (all live DIV1 dependencies).
- `v002/` — target-state diagram (Div1 loop closed).

## What "removing DIV1" actually means here

The pipeline touches DIV1 in two distinct ways — treat them separately:

1. **Reads (re-key, not mechanical):** 4 repos read `div1.tblWell` (+ the producer reads 8 DIV1
   tables for enrichment). Per the 2026-09-09 decision these **re-key on UWI 12/14 and re-source
   from `enverus.data.foundations_wells`** — dropping DIV1 `WellID` and collapsing the 5 lookup
   tables into that one wells table. Not a column-for-column repoint.
2. **The write loop (the hard one):** `landtrac-unit-upload` (the producer) uploads Hendrix SDE
   polygons → prodloader05's **Esri Shapeloader mints `daapUnitID` into `DIV1.tblDaapUnit`** →
   GIS reads it back into Hendrix for tracking. Removing DIV1 means **replacing where
   daapUnitID is minted**. Note the UWI re-key means `daapUnitID` also stops being the Kafka
   message identity (D5a) — a larger downstream change than the reads.

## DIV1 table footprint (verified from repo SQL, 2026-08-31)

| DIV1 table | Consumed by | Role |
|---|---|---|
| tblWell | landtrac-unit-to-kafka, wellid-updates, daapID-update, direct-access-unit-point-feed | WellID / API / well attrs |
| tblDaapUnit | landtrac-unit-to-kafka, wellid-updates, daapID-update | daapUnitID (the frozen table) |
| tblDaapUnitDocumentMapping | landtrac-unit-to-kafka | unit↔document linkage |
| tblAbstract | landtrac-unit-to-kafka | abstract/survey enrichment |
| tblCompany | landtrac-unit-to-kafka | operator/company |
| tblCounty | landtrac-unit-to-kafka | county |
| tblState | landtrac-unit-to-kafka | state |
| tblWellStatus | landtrac-unit-to-kafka | well status lookup |

`landtrac-unit-upload` touches **no** DIV1 table directly — its DIV1 tie is the Shapeloader
round-trip that sets `daapUnitID`.

Under the UWI re-key: `enverus.data.foundations_wells` replaces **tblWell + tblState + tblCounty
+ tblAbstract + tblWellStatus + tblCompany** (6 of the 8 tables retired, since it carries the
resolved `stateprovince`/`county`/`abstract`/`survey`/`envwellstatus`/`envoperator` strings).
Only `tblDaapUnit` (→ new Hendrix sequence) and `tblDaapUnitDocumentMapping` remain to resolve.

## Repo blast radius

| Repo | Role | Change |
|---|---|---|
| direct-access-unit-point-feed | reads `div1.tblWell` | re-key on UWI → `foundations_wells` |
| landtrac-unit-to-kafka | reads 8 DIV1 tables | re-key on UWI → `foundations_wells` (collapses 6 tables) |
| wellid-updates | reads `div1.tblWell` + tblDaapUnit | D2 — likely retire/consolidate |
| daapID-update | reads `div1.tblWell` + tblDaapUnit | D2 — likely retire/consolidate |
| landtrac-unit-upload | **writes DIV1 via Shapeloader** | the hard rework — D1/D3/D6 |
| up-upp-sync, unit-polygon-id, unit-polygon-area-calculation, reconcile-post-all | Hendrix-only | unaffected |

## Hard constraints (do not design around these)

- **`foundations_wells` grain/coverage (verified 2026-09-09).** 6,636,802 rows. `api_uwi_14` is
  ~1:1 (5,723,833 distinct) but **13.8% NULL** — keying on 14 drops ~14% of wells. `api_uwi_12`
  is near-complete (740 NULL) but **fans out** (~308k dup uwi_12 = laterals/wellbores) — must
  dedup to well grain. No native 10-digit key; derive from `*_unformatted`. Pick the failure mode.
- **daapUnitID WAS the Kafka message key** (`landtrac-unit-to-kafka` transform.py:28 → protobuf
  `unit_id`; producer key = `key_base + unit_id`). **The UWI re-key changes this (D5a):** if
  `unit_id` is re-keyed to UWI, every already-published unit (≤ 663970) is re-keyed and all
  downstream consumers fork. Whether consumers accept UWI keys and how existing messages migrate
  is the **largest-blast-radius decision** and gates the source swap. (The old D5 "preserve exact
  daapUnitID / seed from DIV1 MAX+1" constraint is **void if the UWI re-key is adopted**.)
- **daapUnitID is today an *outcome* signal** (set only after a successful Shapeloader ingest),
  which is exactly GIS's freeze-detection tripwire. Minting at upload time changes it to an
  *assignment* signal → that tripwire is lost. A **replacement success indicator** (UC ingest
  timestamp? Kafka-publish confirmation back to Hendrix?) is required, or the next silent stall
  goes undetected (D2a).

## Open decisions (see OFFLINING-DECISIONS.md for full text)

Sequence: **D5a (UWI re-key vs preserve daapUnitID key) and D1 (write direction) are the gates.**
D2/D3/D6 follow.

- **D5a** — UWI re-key vs preserving `daapUnitID` as the Kafka key. **Decided (2026-09-09):** re-key
  on UWI 12/14, source `foundations_wells`. Still open: do downstream consumers accept UWI keys,
  and how are existing daapUnitID-keyed messages migrated? Voids D5 if fully adopted.
- **D1** — where daapUnitID is minted + how it reaches UC. Lean: Hendrix sequence mints →
  Hendrix table = write-side system of record → UC ingests off it.
- **D3** — inventory what the Esri Shapeloader does *besides* mint IDs (NAD83→NAD27 projection,
  validation/repair, the Status/StatusCode IN (1–4) QC promotion gate) before replacing it.
- **D6** — seed / dual-run / rollback cutover. Bounded by D5 (seed from DIV1 MAX+1).

## Why this workspace exists (LND-8911 root cause)

tblDaapUnit froze at 2026-07-14 17:00:28 (last daapUnitId 663970). Cause: the producer's
**empty corrected-units zip crashed the Shapeloader** (`java.util.zip.ZipException`), aborting
each run before it reached the new-units payload. Single blocking failure, not two. The freeze
exposed how brittle the DIV1 round-trip is — hence the offlining proposal. Full diagnostic trail
and the "producer logs lie — go to prod-loader05 Shapeloader logs" gotcha are in the
`reference-landtrac-unit-pipeline` memory.

## Conventions

- This is a docs/diagram workspace — no build, no tests. Edits are to markdown + `.drawio`.
- Commit and push to `main` in the `jira-repos` monorepo.
- Keep V001/V002 diagrams and the decision doc in sync when a decision changes.
