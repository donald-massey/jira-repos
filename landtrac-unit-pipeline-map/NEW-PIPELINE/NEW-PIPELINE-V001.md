# NEW-PIPELINE-V001 — Target Landtrac Unit Pipeline (DIV1 removed, UWI-keyed)

**Purpose.** A single holistic picture of what the GIS landtrac-unit pipeline looks like *after*
DIV1 is offlined and the pipeline re-keys on UWI 12/14 — with every open decision resolved to a
**recommended** value so the design reads as one coherent whole. This is a **presentation draft**,
not a commitment: each decision below carries the team **options** beside the recommendation, so the
GIS + Land Data teams can swap any choice and see what moves. Implementation starts only from the
choices the team ratifies.

Companion docs: `OFFLINING-DECISIONS.md` (the authoritative decision set, D1–D6/D5a) and the V001
(current) / V002 (loop-closed) diagrams. This file assumes those decisions land on the recommended
values and draws the resulting end-state.

**How to read it:** every stage names its governing decision (D1…D6). `✅ Recommended` is the value
baked into this draft; `⇄ Options` are the alternatives the team can pick instead. Nothing here is
built until ratified.

---

## 1. The target pipeline at a glance

```
                        ┌─ Databricks Unity Catalog ──────────────┐
                        │  enverus.data.foundations_wells          │
                        │  (well enrichment, keyed on UWI 12/14)   │
                        └───────────────┬──────────────────────────┘
                                        │ well data (UWI-keyed)
GIS Manufacturing (aus2-gis-pmfg01)     ▼
  GIS Team edits ─► SDE.EDITORS ─► reconcile-post-all ─► SDE.DEFAULT
                                        │
  landtrac-unit-upload ──── QC'd polygons ───► Hendrix landtrac_unit.sde
     (writes Hendrix directly,                    UNIT_POLYGON  (+ daapUnitID native)
      NO prodloader05 hotfolder)                  UNIT_POINT_PROD
                                        ▲              │
                     Hendrix unit-id sequence ★NEW ────┘ mints daapUnitID on load
                     (seeded from DIV1 MAX+1 = 663970, monotonic)
                                        │
                                        ▼
  landtrac-unit-to-kafka (Airflow producer) ── enrich: foundations_wells + DS9 ──►
                                        │
             ┌──────────────────────────┴───────────────────────────┐
             ▼                                                        ▼
  Kafka dp.pres.landtracunit.v4  ★NEW (key = UWI)      Kafka dp.pres.landtracunit.v3 (key = daapUnitID)
             │  recommended steady-state                 │  runs in PARALLEL during transition, retired when drained
             ▼                                            ▼
  dataset-materialization-service ─► Prefect orchestrates ─► 6 publish targets
     (Direct Access · DIBI · Prism · Elasticsearch · DS9 · Hendrix gis_exports)
```

**One-sentence summary:** DIV1 disappears on both sides — the producer's well enrichment comes from
`foundations_wells` in Unity Catalog keyed on UWI, and `daapUnitID` is minted by a new Hendrix
sequence instead of the prodloader05/Shapeloader round-trip; the message identity moves to UWI on a
new `v4` topic that runs alongside `v3` until consumers migrate.

---

## 2. Stage-by-stage target design

### 2.1 Well enrichment source — `foundations_wells` on UWI  *(D4 + UWI pivot)*

**✅ Recommended.** The producer and the point-feed read `enverus.data.foundations_wells` from the
Databricks "Enverus Lake" connection, keyed on **`api_uwi_12` with a dedup/roll-up to one row per
well**. This single table carries the resolved strings the producer today rebuilds through five DIV1
lookup joins (`county`, `stateprovince`, `abstract`, `survey`, `envwellstatus`, `envoperator`), so it
**retires 6 of the 8 DIV1 tables outright**: `tblWell + tblState + tblCounty + tblAbstract +
tblWellStatus + tblCompany`. Only `tblDaapUnit` (→ Hendrix sequence, §2.2) and
`tblDaapUnitDocumentMapping` remain to resolve.

Why uwi_12+dedup over uwi_14: `api_uwi_14` is a clean ~1:1 key but **13.8% of rows (912,958) have a
NULL uwi_14** — keying strictly on 14 silently drops ~14% of the well universe. `api_uwi_12` has only
740 NULLs (near-complete coverage) but **fans out** (~308k uwi_12 values sit on multiple
wellbore/lateral rows), so it must be rolled up to well grain before the unit↔well join. Coverage is
the safer failure mode for a data-completeness pipeline.

**⇄ Options:**
- *Key on `api_uwi_14`* — accept the 13.8% coverage loss in exchange for a clean 1:1 join and no
  dedup step. Viable only if the null-uwi_14 wells are confirmed out-of-scope for landtrac units.
- *Mirror the 8 DIV1 tables into UC* instead of re-keying — column-for-column repoint, preserves
  `WellID`/`daapUnitID` identity (voids the whole UWI pivot and D5a). Lower design risk, but keeps a
  DIV1-shaped schema alive and doesn't deliver the "new identifiers" goal.

**⚠ Pre-work gating this (unchanged from D4):** the GIS service principal still needs UC read grants
on the wells catalog, then two validations that require DIV1 + UC reachable together: (1) **coverage
join** — what % of today's DIV1 well universe by UWI actually exists in `foundations_wells`; (2)
**attribute-vocab parity** — `envwellstatus` strings vs DIV1 `wellStatusID` codes, operator naming.
Also confirm the **unit↔well match length** (the pipeline historically joined on API-10;
`foundations_wells` exposes 12/14, so a 10-digit key is derived and many-to-one).

### 2.2 Where daapUnitID is minted — new Hendrix sequence  *(D1)*

**✅ Recommended: Hendrix-authoritative with UC ingest.** A new Hendrix sequence/table mints
`daapUnitID` when a QC'd polygon lands in `UNIT_POLYGON`, replacing the prodloader05 Shapeloader's
on-import minting. **Hendrix becomes the write-side system of record; UC ingests off the Hendrix
table as a downstream copy.** This keeps the id assignment inside the system GIS already owns and
monitors, and removes the cross-DB DIV1 write entirely.

The sequence is **not free to pick values** (this is the D5-derived constraint that survives even
though the Kafka key moves — see §2.4). It must be **seeded from the current DIV1 `tblDaapUnit`
state**, set next-value = **MAX+1 (663970+1)**, and continue monotonically with no reuse, so every
already-minted unit keeps its historical `daapUnitID` as a stable lineage attribute.

**⇄ Options:**
- *Direct UC write path* — `landtrac-unit-upload` (or a successor) writes the minted id straight to
  UC, Hendrix reads it back. Rejected as the recommendation because it inverts today's ownership (GIS
  loses local authority over its own id) and adds a UC round-trip to the upload critical path.

### 2.3 Replacing the Esri Shapeloader — inventory before removal  *(D3, PRE-WORK)*

The DIV1 round-trip is not only where `daapUnitID` was minted — it's the **promotion path** from an
edited SDE polygon to a registered prod unit. The direct-to-Hendrix write in §2.2 must explicitly
replicate whatever the Shapeloader did besides mint IDs, or behavior nothing else replaces is silently
dropped. Three items to resolve **before** the writer is rebuilt:

- **Projection (NAD83→NAD27 / NADCON).** Determine whether any downstream consumer actually requires
  NAD27 or it was purely the old Esri loader's expected input. **✅ Recommended default:** if no
  consumer needs NAD27, keep polygons in **NAD83** and drop NADCON. **⇄ Option:** preserve the NAD27
  projection step in the new writer if a consumer dependency is found.
- **Validation / repair / topology.** Confirm whether the Shapeloader ran make-valid / dedup /
  topology checks nothing else does; if so, port them into the upload path (Shapely `make_valid` is
  the natural home given the geom-spark precedent).
- **Promotion / QC gate.** Confirm the `Status`/`StatusCode IN (1–4)` QC promotion gate — what
  distinguishes the SDE editing polygon from a registered `UNIT_POLYGON` row. The new writer must
  enforce the same gate on direct write.

### 2.4 Message identity — UWI on a new `v4` topic  *(D5a — the largest blast radius)*

**✅ Recommended: re-key to UWI on a new topic `dp.pres.landtracunit.v4`, run in parallel with `v3`.**
The producer publishes UWI-keyed messages to **`dp.pres.landtracunit.v4`** (`unit_id` = UWI 12/14,
key = `key_base + UWI`). The existing **`dp.pres.landtracunit.v3`** topic (keyed on `daapUnitID`)
**keeps running in parallel**; each consumer — DSM, DirectAccess, DIBI, Prism, Elasticsearch, DS9,
Hendrix gis_exports — migrates from v3→v4 on its own schedule. `v3` is retired once all consumers
have drained. `daapUnitID` is retained as a **stable payload attribute** on v4 for lineage and
back-compat, even though it is no longer the key.

Why the parallel-topic path: re-keying is the single largest-blast-radius change in the whole effort
(every downstream consumer is keyed on `daapUnitID` today). A new versioned topic makes the cutover
**incremental and reversible** — no big-bang, no simultaneous re-key of every target, and v3 is a
live fallback the entire time. The cost is running two topics and the producer double-publishing
during the transition window.

**⇄ Options:**
- *Keep `daapUnitID` as the key, UWI source-only* — **lowest blast radius.** `daapUnitID` (minted by
  the Hendrix sequence, §2.2) stays the Kafka key; UWI is re-sourced enrichment in the payload only,
  no consumer forks, D5 preserved intact. Choose this if the team decides the "new identifier" goal is
  satisfied by re-sourcing wells on UWI **without** changing the message identity. It is the smallest
  change and worth stating plainly as the fallback if v4 is judged too much infra.
- *Re-key to UWI, republish all v3 history in place* — hard big-bang cutover: backfill every
  already-published unit (≤ 663970) under new UWI keys on the same v3 topic, all consumers re-key at
  once. Highest risk, least operational overhead long-term. Not recommended given the consumer count.

**⚠ Still owed regardless of option:** do downstream consumers *accept* UWI-shaped keys at all, and
what is the per-consumer migration order? That inventory is the first task if v4 is ratified.

### 2.5 Freeze-detection signal + tracking scripts  *(D2 / D2a)*

**The problem D2a names:** today `daapUnitID` is an **outcome** signal — it only exists after a
successful Shapeloader ingest, which is exactly GIS's freeze-detection tripwire (the LND-8911 stall
was caught because `tblDaapUnit` stopped advancing). Minting in Hendrix at *upload* time changes it to
an **assignment** signal, so that tripwire is lost. A **replacement success indicator is required** or
the next silent stall goes undetected.

**✅ Recommended:**
- **New success indicator:** a **Kafka-publish confirmation written back to a Hendrix tracking
  column** (per unit: "reached v4 / materialized / published"). A UC-ingest timestamp is the
  secondary candidate; the publish confirmation is preferred because it proves the record reached the
  actual downstream, which is what the old signal implicitly meant.
- **Consolidate the two tracking scripts** (`wellid-updates`, `daapID-update`) into **one job** that
  reads UC → updates the Hendrix tracking table → performs the wellid/daapid backfill in a single
  script, carrying the new success indicator. This collapses the Py2/Py3 overlap the two scripts have
  today.

**⇄ Options:**
- *Re-source both scripts, keep them separate* — repoint each from DIV1→UC individually, carry the new
  indicator, don't consolidate. Less refactoring, keeps the existing schedule split.
- *Retire both without replacement* — only viable if `daapUnitID`-as-assignment is accepted **and**
  the success indicator lives elsewhere (e.g. inside the producer). Highest cleanup, but leaves no
  GIS-side tracking job — not recommended given the freeze-detection lesson.

### 2.6 Cutover, seeding, rollback  *(D6)*

**✅ Recommended sequence:**
1. **Seed** — one-time snapshot of DIV1 `tblDaapUnit` → new Hendrix sequence/table, set next-value =
   MAX+1 (663970+1). Snapshot-and-flip.
2. **Dual-run validation** — run the UC-sourced producer beside the DIV1-sourced one and **diff the
   Kafka output** (same units, same enrichment) before any consumer cutover. Gated on the D4 pre-work
   (UC granted + populated + freshness confirmed).
3. **Parallel publish** — producer double-publishes to v3 (daapUnitID) and v4 (UWI); consumers migrate
   v3→v4 independently; retire v3 when drained (§2.4).
4. **Rollback** — during the window, if UC freshness lags and units would emit incomplete, fall back
   to the DIV1-sourced producer / v3. **Note the expiry:** DIV1 is being retired org-wide, so
   "repoint to DIV1" has a hard deadline — confirm that window before relying on it as the rollback.

**⇄ Option:** *dual-write DIV1 + Hendrix during the transition* (instead of snapshot-and-flip) so both
id stores stay consistent while consumers migrate — heavier, but removes the flip-day risk.

---

## 3. Repo-by-repo target state

| Repo | Today | Target state | Decision | Effort |
|---|---|---|---|---|
| `direct-access-unit-point-feed` | reads `div1.tblWell` | re-source well data from `foundations_wells` (UWI); DA V2 point ingest unchanged | D4 | Low — repoint read |
| `landtrac-unit-to-kafka` (producer) | reads 8 DIV1 tables; publishes v3 keyed on daapUnitID | reads `foundations_wells` (UWI, retires 6 tables) + DS9; publishes **v4 keyed on UWI** (v3 in parallel during transition) | D4, D5a | **High** — re-source + re-key + double-publish |
| `landtrac-unit-upload` (writer) | pushes polygons to prodloader05 hotfolder → DIV1 Shapeloader mints daapUnitID | writes QC'd polygons **direct to Hendrix `UNIT_POLYGON`**; new Hendrix sequence mints daapUnitID; ports Shapeloader QC/projection/validation | D1, D3, D6 | **Highest** — the hard rework |
| `wellid-updates` + `daapID-update` | two scripts read `div1.tblWell ⨝ tblDaapUnit`, backfill UPP | **consolidated** into one UC-sourced job that also carries the new publish-confirmation success signal | D2 | Medium — merge + re-source |
| `up-upp-sync`, `unit-polygon-id`, `unit-polygon-area-calculation`, `reconcile-post-all` | Hendrix-only | **unchanged** | — | None |

---

## 4. What stays the same

- **Everything from the Airflow producer rightward is structurally unchanged** — DSM, the Prefect
  orchestration flow (Materialize→Prepublish→Verify→Publish→Clean), and all **6 publish targets**
  (Direct Access, DIBI, Prism, Elasticsearch, DS9, Hendrix `gis_exports`). The only change they see is
  a new topic/key to migrate onto (§2.4), and only if the v4 option is ratified.
- **The Hendrix SDE hub** (`landtrac_unit.sde` on `v03henpdb01`) stays the center of gravity — it
  gains the native `daapUnitID` sequence and the tracking column, but `UNIT_POLYGON` / `UNIT_POINT_PROD`
  / `unit_point` are the same tables.
- **DS9 enrichment** (well status, entitlement, basin/play) is untouched — the UWI pivot only replaces
  the *DIV1* enrichment, not DS9.
- **`reconcile-post-all`** remains the step that makes GIS-team versioned edits visible to the producer.

---

## 5. Open items still needing team ratification / pre-work

These are the things this draft *assumed* to make the picture coherent — each is where the team can
still change the answer:

1. **D5a consumer acceptance** *(gates v4)* — do the 6 targets + DSM/DirectAccess/Prism accept
   UWI-shaped keys, and in what migration order? First task if v4 is ratified.
2. **UWI grain** — uwi_12+dedup (recommended, coverage) vs uwi_14 (clean, −13.8% coverage). Pick the
   failure mode.
3. **D4 pre-work** — UC read grants for the GIS service principal; then coverage-join %, attribute
   vocab parity, and unit↔well match length. Nothing downstream is buildable until the grant lands.
4. **D3 Shapeloader inventory** — projection (keep NAD27?), validation/repair, QC promotion gate.
   Blocks rebuilding the writer safely.
5. **D2a success signal shape** — Kafka-publish confirmation (recommended) vs UC-ingest timestamp.
6. **D6 rollback window** — confirm how long "repoint to DIV1" remains available before org-wide DIV1
   retirement closes it.

---

## 6. Decision summary — recommended vs. options

| # | Decision | ✅ Recommended (baked into this draft) | ⇄ Alternatives | Reversible? |
|---|---|---|---|---|
| D4 | Well source + key | `foundations_wells`, **uwi_12 + dedup** | uwi_14 (−14% cov); mirror 8 DIV1 tables | Med — re-key is invasive |
| D1 | daapUnitID minting | **Hendrix sequence**, UC ingests off it | Direct UC write path | Low — pick before build |
| D3 | Shapeloader replacement | **Drop NAD27** if no consumer needs it; port validation + QC gate | Preserve NAD27 | Low — config |
| D5a | Message identity | **UWI on new `v4` topic, v3 in parallel** | Keep daapUnitID key (UWI source-only); big-bang re-key on v3 | Hard — largest blast radius |
| D2 | Tracking scripts + signal | **Consolidate to one UC job**; **publish-confirmation** signal | Re-source separately; retire both | Med |
| D6 | Cutover | **Seed MAX+1 → dual-run diff → parallel v3/v4 → retire v3** | Dual-write DIV1+Hendrix in transition | Hard — go-live |

*Draft prepared 2026-09-09 alongside `OFFLINING-DECISIONS.md`. Recommended values are starting
positions for GIS + Land Data ratification, not commitments.*
