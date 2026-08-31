# CONTEXT — Offline prodloader05 → Div1 Landtrac Unit Upload (Close the Div1 Loop)

Stress-test workspace for the V001/V002 offlining proposal (spun out of LND-8911).
Purpose: surface every decision/question the GIS + Land Data teams must resolve before committing.

## Scope (decided)

- This is **one slice of a broader DIV1 → Databricks Unity Catalog migration**. UC becomes the
  **source of record** for the DIV1 tables.
- **GIS Team processes only.** Other teams/processes that read DIV1 directly own their own
  migration — explicitly out of scope here. No need to inventory external DIV1 consumers for this effort.

## Glossary

- **daapUnitID** — surrogate key for a landtrac unit. Today minted by the Esri Shapeloader when it
  writes `DIV1.tblDaapUnit`. Historically doubled as the GIS team's "polygon loaded downstream" signal.
- **Div1 loop** — the round trip where GIS uploads polygons → prodloader05 mints daapUnitID in DIV1 →
  GIS reads daapUnitID back into Hendrix for tracking.
- **UNIT_POLYGON / UNIT_POINT_PROD** — Hendrix prod (`v03henpdb01`) tables in the `landtrac_unit` SDE.
- **Producer** — `landtrac-unit-upload` (GIS/git.drillinginfo.com); the writer.

## Repo blast radius (from V001)

Reads `div1.tblWell` (→ repoint to UC): direct-access-unit-point-feed, wellid-updates, daapID-update, landtrac-unit-to-kafka
Writes DIV1 (the hard one): landtrac-unit-upload
Unaffected (Hendrix-only): up-upp-sync, unit-polygon-id, unit-polygon-area-calculation, reconcile-post-all

## Open decisions

**D1 — Write chain / where daapUnitID becomes authoritative. [TEAM DECISION: GIS + Land]**
Reader repos just repoint to UC. But `landtrac-unit-upload` is a *writer* — today it causes the
Shapeloader to mint `daapUnitID` into `DIV1.tblDaapUnit`. New chain must define: where is daapUnitID
physically minted, and how does it reach UC?
- Lean (Donald): Hendrix sequence mints daapUnitID → write to a Hendrix table → UC ingests off that
  Hendrix table (Hendrix = write-side system of record, UC = downstream copy).
- Team must confirm the direction: Hendrix-authoritative-with-UC-ingest vs. a direct UC write path.
- Determines the new write target for every downstream reader.

**D2 — Fate of wellid-updates / daapID-update + the lost "loaded" signal. [TEAM: options to weigh]**
Today daapUnitID is an *outcome* signal (set only after a successful Shapeloader ingest). A Hendrix
sequence minting at upload time changes it to an *assignment* signal, so GIS loses its freeze-detection
tripwire (the exact LND-8911 failure). Two coupled questions:
- (a) New success indicator to replace daapUnitID's "reached UC/Kafka/DA" meaning — UC ingest
  timestamp? Kafka-publish confirmation back to Hendrix? Needed or GIS can't detect the next silent stall.
- (b) The two tracking scripts.
Options:
  1. Retire both; fold their work into a single new consolidated job that reads UC → updates a Hendrix
     table → performs the wellid/daapid updates in one script (Donald's lean). Solve (a) inside it.
  2. Keep them, re-sourced from UC instead of DIV1, carrying the new success indicator.
  3. Retire without replacement (only if daapUnitID-as-assignment is accepted and (a) solved elsewhere).
