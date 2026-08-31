# Offlining prodloader05 → Div1 — Decisions & Open Questions

Companion to the V001 (current DIV1 dependencies) and V002 (Div1 loop closed) diagrams in this repo.
Product of a grill-with-docs stress-test of the offlining proposal (spun out of LND-8911).
Purpose: give GIS + Land Data teams the full decision set required **before** committing to the migration.

Legend: **[DECIDED]** settled · **[TEAM]** needs GIS + Land Data ratification · **[PRE-WORK]** must be
investigated before the decision can even be made.

---

## Scope [DECIDED]

- One slice of a broader **DIV1 → Databricks Unity Catalog migration**. UC becomes the **source of record**
  for the DIV1 tables.
- **GIS Team processes only.** Other teams/processes that read DIV1 directly own their own migration —
  out of scope here. No external-DIV1-consumer inventory needed for this effort.

## Glossary

- **daapUnitID** — surrogate key for a landtrac unit. Today minted by the Esri Shapeloader when it writes
  `DIV1.tblDaapUnit`. Historically doubled as GIS's "polygon loaded downstream" outcome signal.
- **Div1 loop** — GIS uploads polygons → prodloader05 mints daapUnitID in DIV1 → GIS reads it back into
  Hendrix for tracking.
- **UNIT_POLYGON / UNIT_POINT_PROD** — Hendrix prod (`v03henpdb01`) tables in the `landtrac_unit` SDE.
- **Producer** — `landtrac-unit-upload` (GIS/git.drillinginfo.com); the writer of the loop.

## Repo blast radius (from V001)

| Repo | Role | Change |
|---|---|---|
| direct-access-unit-point-feed | reads `div1.tblWell` | repoint read → UC |
| wellid-updates | reads `div1.tblWell` | see D2 (likely retire/consolidate) |
| daapID-update | reads `div1.tblWell` | see D2 (likely retire/consolidate) |
| landtrac-unit-to-kafka | reads `div1.tblWell` | repoint read → UC |
| landtrac-unit-upload | **writes DIV1** | the hard one — see D1 |
| up-upp-sync, unit-polygon-id, unit-polygon-area-calculation, reconcile-post-all | Hendrix-only | unaffected |

---

## DIV1 table footprint (verified from source, 2026-08-31)

Complete set of DIV1 tables the GIS unit pipeline touches (from the actual repo SQL, not the diagram's "7"):

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

Note: `landtrac-unit-upload` (the writer) touches **no** DIV1 tables directly — it reads only the Hendrix
SDE (`UNIT_POINT_PROD` ⨝ `UNIT_POLYGON`); its DIV1 tie is the Shapeloader round-trip that sets `daapUnitID`.

## UC availability check (BLOCKER — verified 2026-08-31)

Queried Unity Catalog (Databricks "Enverus Lake") directly. **None of the 8 DIV1 tables above are present
or reachable** under the GIS service connection:
- No `div1`/`div1_daily` schema exists in any visible catalog; metastore-wide name search for
  daap/well/abstract source tables returns nothing matching (only `enverus.diweb.wells`, a DI Web product).
- **Presumed home: `ea_wells_prod`** (Donald). But this catalog exposes **only `information_schema`** to the
  current connection — even `ea_wells_prod.information_schema.schemata` lists nothing but itself. UC filters
  information_schema by grant, so the 8 tables are **unverifiable from here, not confirmed absent**. The
  access gap is itself a pre-work blocker: the GIS service principal needs UC read grants on `ea_wells_prod`
  before the producer can be re-sourced — and before anyone can even run the table/column/freshness gap check.
- `ea_gis_prod` behaves identically (information_schema only); direct DESCRIBE of guessed schemas → TABLE_NOT_FOUND.
- Only raw/bronze schemas visible are `ea_land_prod.bronze` (courthouse lease loader `chldl_*`) and
  `ea_ok_reg_dev.ingest` — neither carries DIV1 unit data.
- DirectAccess delta-sharing (`cts_deltasharing_da_*.direct_access_v3`) has `foundations_landtracunits`,
  `core_landtracunitrollups`, `core_wells`, `global_well` — but these are pipeline **outputs/products**,
  not the DIV1 enrichment source; different grain and freshness. (Possible WellID re-source candidate only.)
- **Partial hit — `enverus.diweb.wells` (reachable):** 467 cols incl. `WellId, UWI, API10/12/14, WellStatus`.
  Candidate source for the 4 WellID reader repos ONLY. Caveats: (1) DI Web `WellId` may be a different
  identity space than DIV1 `tblWell.WellID` — the readers join on DIV1's WellID/uwi, so this needs a
  **value-level match check** before trusting it; (2) it's a DI Web product (freshness vs DIV1 unknown);
  (3) it does nothing for the producer's other 7 tables (Abstract/Company/County/State/WellStatus/
  DaapUnitDocumentMapping/DaapUnit), which remain unlocated.

**D4 — Confirm the 8 tables in UC + freshness. [PRE-WORK → GIS/Land]**
Grant the GIS service principal UC read on `ea_wells_prod`, then verify: (1) all 8 tables present,
(2) join columns match what the repo SQL uses, (3) replication lag vs DIV1 is inside the daily cycle
(freshness — item 2 from the original grill; a morning upload's enrichment rows must be in UC same-run).

## Open decisions

### D1 — Write chain / where daapUnitID becomes authoritative  [TEAM]
Reader repos just repoint to UC. But `landtrac-unit-upload` is a *writer* — today it causes the Shapeloader
to mint `daapUnitID` into `DIV1.tblDaapUnit`. New chain must define: where is daapUnitID physically minted,
and how does it reach UC?
- **Lean (Donald):** Hendrix sequence mints daapUnitID → write to a Hendrix table → UC ingests off that
  Hendrix table (Hendrix = write-side system of record, UC = downstream copy).
- Team must confirm direction: **Hendrix-authoritative-with-UC-ingest** vs. a **direct UC write path**.
- Determines the new write target for every downstream reader.

### D2 — wellid-updates / daapID-update + the lost "loaded" signal  [TEAM]
A Hendrix sequence minting at upload time changes daapUnitID from an *outcome* signal to an *assignment*
signal → GIS loses its freeze-detection tripwire (the exact LND-8911 failure). Two coupled parts:
- **(a) New success indicator** to replace daapUnitID's "reached UC/Kafka/DA" meaning — UC ingest
  timestamp? Kafka-publish confirmation back to Hendrix? Required, or GIS can't detect the next silent stall.
- **(b) The two tracking scripts.** Options:
  1. **Consolidate (Donald's lean):** retire both; one new job reads UC → updates a Hendrix table →
     performs wellid/daapid updates in a single script. Solve (a) inside it.
  2. **Re-source:** keep both, repointed from DIV1 → UC, carrying the new success indicator.
  3. **Retire without replacement:** only if daapUnitID-as-assignment is accepted and (a) is solved elsewhere.

### D5 — daapUnitID is the Kafka identity → minting-continuity constraint  [HARD CONSTRAINT on D1]
Verified in `landtrac-unit-to-kafka`: `daapUnitID` maps to protobuf `unit_id` (transform.py:28), is the
enrichment join key, AND is the **Kafka message key** (`main.py:21` "keyed to daapUnitID"; producer key =
`key_base + unit_id`). So the compacted topic, DSM, Prefect, all 6 publish targets, DirectAccess, and Prism
are **all keyed on daapUnitID**.
Consequence for the D1 "new Hendrix sequence" lean — the sequence is NOT free to pick values. It must:
1. **Preserve the exact existing daapUnitID** for every already-published unit (≤ 663970) — a fresh IDENTITY
   column would re-key every unit and fork the entire downstream (dup or orphaned units everywhere).
2. **Continue monotonically above the DIV1 MAX (663970)** with no collisions, never reassign/reuse.
3. Therefore be **seeded from DIV1 tblDaapUnit's current state**, not started from scratch.
This is the strongest argument for the Hendrix-authoritative direction in D1 — but only if seeded correctly.

### D3 — What the Esri Shapeloader does besides mint IDs  [PRE-WORK → GIS]
The DIV1 round-trip is also the **promotion path** from an edited SDE polygon to a registered prod unit.
Cutting out the Shapeloader may silently drop behavior nothing else replicates. Unknown today — inventory
the Shapeloader before designing its replacement. Specifically resolve:
- **Projection:** why does NAD83→NAD27 (NADCON) exist? Does any downstream consumer require NAD27, or is it
  purely the old Esri loader's expected input? Direct-to-Hendrix → keep NAD83 and drop NADCON, or preserve NAD27?
- **Validation/repair/topology:** did the Shapeloader do make-valid / dedup / topology checks nothing else does?
- **Promotion semantics:** what distinguishes the SDE editing polygon from `UNIT_POLYGON`? Does the loader
  round-trip currently enforce the Status/StatusCode IN (1–4) QC gate?

### D6 — Cutover / seeding / rollback  [TEAM]
Plan (Donald): replace the Shapeloader's daapUnitID minting with **a Hendrix table that performs the same
function** (assign daapUnitID on upload). Open for the team. Bounded by D5 — the Hendrix authority must be
**seeded from the current DIV1 tblDaapUnit and continue above MAX (663970)**, not clean-slate.
Sub-decisions:
- **Seed:** one-time snapshot of DIV1 tblDaapUnit → Hendrix, set next-value = MAX+1. Snapshot-and-flip, or
  dual-write DIV1+Hendrix during a transition window while consumers migrate?
- **Validate:** dual-run the UC-sourced producer beside the DIV1-sourced one and diff Kafka output (same
  keys, same enrichment) before cutover? (Gated on D4 — UC populated + granted first.)
- **Rollback:** if UC freshness lags and units emit incomplete, fall back to DIV1 or halt? Note DIV1 is being
  retired org-wide, so "repoint to DIV1" has an expiry — confirm the window.

---

## Advisory summary — what the team must resolve before committing

**Sequence the decisions:** D1 (write direction) and D4 (UC access + table/freshness) are the gates —
nothing else can be designed until those two are settled. D5 is a fixed constraint that every option must
honor. D2/D3/D6 are design choices that follow.

| # | Decision | Type | Blocks |
|---|---|---|---|
| D1 | Where daapUnitID is minted + how it reaches UC | TEAM | everything |
| D4 | 8 DIV1 tables present + granted + fresh in `ea_wells_prod` | PRE-WORK | producer + 4 readers re-source |
| D5 | daapUnitID minting must be seeded from DIV1 (Kafka key) | HARD CONSTRAINT | D1, D6 |
| D3 | Inventory what the Esri Shapeloader does besides mint | PRE-WORK | replacing the writer safely |
| D2 | New "loaded" success signal + fate of the 2 tracking scripts | TEAM | freeze-detection, script rework |
| D6 | Seed / dual-run / rollback cutover strategy | TEAM | go-live |

**Known scope of change:** 4 reader repos repoint `tblWell` → UC (mechanical). 1 writer repo
(`landtrac-unit-upload`) is the hard rework. 8 DIV1 tables to re-source. 4 Hendrix-only repos untouched.