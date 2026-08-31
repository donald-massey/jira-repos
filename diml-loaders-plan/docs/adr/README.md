# Architecture Decision Records

Decisions with lasting consequence for the DIML loaders — recorded when they are
hard to reverse, surprising without context, and the result of a genuine trade-off.
Domain vocabulary lives in [`../../CONTEXT.md`](../../CONTEXT.md).

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-per-batch-checkpointing-iie-loader.md) | Per-batch checkpointing for the IIE loader | Proposed |
| [0002](0002-contain-start-running-blast-radius.md) | Recover from a leaked `start_running` lock (no schema change) | Proposed |
| [0003](0003-per-run-window-cap.md) | Per-run window cap for the IIE loader | Proposed |

All three are **no-schema-change** proposals.

## How they fit

- **0001** makes any crash cheap — a run resumes from the last committed batch instead
  of reprocessing the whole window. Also delivers incremental cross-run progress.
- **0003** bounds how much one run attempts (upfront query + run duration), so crashes
  and Nomad timeouts are rarer. Composes with 0001: 0003 prevents most crashes, 0001
  makes any that happen cheap.
- **0002** handles the case where a crash *does* leak the `running` lock. Two
  candidate directions: self-heal the stale lock via a Nomad liveness check (preserves
  the deliberate one-at-a-time policy), or narrow the wildcard so only the crashed
  priority pauses (relaxes that policy). See the ADR — the choice is open.

## Open questions to resolve before implementing

- **0002** — the wildcard is a *deliberate* one-at-a-time policy (LND-6284), so pick a
  direction: the Nomad-liveness self-heal avoids touching the policy; narrowing it is
  only safe once LND-6284's rationale (resource contention vs. dedup race) is known.
- **0003** — is `diml_es.query_diml_es_index` paginated, and what is the Nomad
  allocation's max runtime? These decide whether the cap is needed over 0001 alone.
