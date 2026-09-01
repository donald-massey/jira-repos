# Architecture Decision Records

Decisions with lasting consequence for the DIML loaders — recorded when they are
hard to reverse, surprising without context, and the result of a genuine trade-off.
Domain vocabulary lives in [`../../CONTEXT.md`](../../CONTEXT.md).

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-per-batch-checkpointing-iie-loader.md) | Periodic (every-10-batch) checkpointing for the IIE loader | Accepted (LND-8967) |
| [0002](0002-contain-start-running-blast-radius.md) | Recover from a leaked `start_running` lock (no schema change) | Proposed |
| [0003](0003-per-run-window-cap.md) | Per-run *window* cap for the IIE loader | Deferred — superseded by 0005 |
| [0004](0004-engine-reuse-fix-per-iteration-leak.md) | Fix the per-iteration SQLAlchemy engine leak by reusing one instance | Accepted (LND-8967) |
| [0005](0005-per-run-batch-cap-iie-loader.md) | Per-run *batch* cap for the IIE loader (`IIE_MAX_BATCHES`) | Accepted (LND-8967) |

All are **no-schema-change** decisions.

**Scope:** 0001, 0004, 0005 are the accepted LND-8967 work. 0002 (leaked-lock recovery)
and the [monitoring proposal](../monitoring/loaderstatus-sla.md) are the broader
diml-loaders effort, parked here — they likely belong to their own card. 0003 is the
deferred time-window alternative to 0005.

## How they fit

- **0004** stops per-loop memory growth *within* a run (one engine + pool per run, not
  one per iteration) — the immediate OOM fix.
- **0005** bounds how many batches one run processes (`IIE_MAX_BATCHES=400`), so a
  single run can't get large enough to OOM or hit the Nomad timeout. Does not bound the
  upfront `get_datasets` query (see 0005's residual-gap note; that was 0003's target).
- **0001** makes any crash that still happens cheap — a run resumes from the last
  checkpointed batch (every-10) instead of reprocessing the whole window. Composes with
  0005: the cap leaves `lastLoaded` at the last committed batch and the next run resumes.
- **0002** handles the case where a crash *does* leak the `running` lock. Two candidate
  directions (Nomad-liveness self-heal vs. narrow the wildcard) — the choice is open.
- **0003** (deferred) would additionally bound the upfront query + run duration via a
  time window; revisit if 0005's residual gap bites.

## Open questions to resolve before implementing

- **0002** — the wildcard is a *deliberate* one-at-a-time policy (LND-6284), so pick a
  direction: the Nomad-liveness self-heal avoids touching the policy; narrowing it is
  only safe once LND-6284's rationale (resource contention vs. dedup race) is known.
- **0003 / 0005** — is `diml_es.query_diml_es_index` paginated, and what is the Nomad
  allocation's max runtime? These decide whether 0005's upfront-query gap needs 0003's
  time-window cap on top of it.
