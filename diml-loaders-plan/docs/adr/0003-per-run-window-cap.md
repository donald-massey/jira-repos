# ADR 0003: Per-run window cap for the IIE loader

- **Status:** Proposed
- **Date:** 2026-08-31
- **Component:** `main.py`

## Context

A run's query window ends at "now": `this_load_date = utcnow()`. So a single run
attempts every dataset from `lastLoaded` to the present. For the daily `high`
priority this is fine — the window is ~a day. For the historical `medium` / `low`
priorities recovering a large backlog (observed: `medium` six weeks behind), one run
tries to process the entire backlog at once.

Two clarifications on what this does *not* solve, to avoid over-crediting the cap:

- The loader **already batches** the full lookback. Batching bounds *peak memory*
  (one batch in the session at a time) — nothing else.
- **Per-batch checkpointing (ADR 0001)** is what makes progress *incremental across
  runs*: a run that dies resumes from the last committed batch. That is not this
  ADR's contribution.

What remains unbounded even with ADR 0001 in place is: (a) `get_datasets`
materializes the **entire window's** dataset metadata in one list *before* the first
batch runs; and (b) run **wall-clock is unbounded** and can hit the Nomad job
timeout — itself a hard kill, which is exactly the leaked-lock trigger ADR 0002
addresses. Those two — the upfront query and run duration — are what this ADR bounds.

The scheduler is well-suited to incremental draining: the DAG cron fires roughly
sixteen times per weekend. What is missing is a bound on how much each run bites off.

## Decision

Cap the window's end bound, anchored on `lastLoaded`:

```
this_load_date = min(utcnow(), lastLoaded + WINDOW)
```

where `WINDOW` is configurable (e.g. `IIE_WINDOW_DAYS`, default ~3 days). Anchor on
`lastLoaded`, **not** on the overlap-adjusted window start, so the net forward
advance per successful run equals `WINDOW` exactly.

- **Caught up** (`lastLoaded + WINDOW > now`): the bound collapses to `now` — daily
  behavior is unchanged.
- **Behind**: each run processes one `WINDOW` slice, advances `lastLoaded` by
  `WINDOW`, and exits. Successive cron runs drain the backlog one bounded slice at a
  time.

This is a change to date computation in `main.py` only. The loader, checkpointing
(ADR 0001), and per-batch memory limits are untouched and compose with it: `WINDOW`
bounds *run duration and datasets pulled*, batch size bounds *peak memory*, and
per-batch checkpointing makes a mid-slice crash cheap to resume.

## Consequences

**Positive**
- No single run attempts an unbounded backlog; the upfront `get_datasets` list and
  run duration are bounded and predictable. Predictable duration also means fewer
  Nomad-timeout hard kills — the leaked-lock trigger ADR 0002 has to contain.
- Backlog drain becomes a tunable trade-off via one env var, no redeploy.

**Negative / accepted trade-offs**
- **Drain time vs. run size.** Smaller `WINDOW` = safer per run but more runs and a
  longer calendar drain (bounded by the weekend-only schedule); larger `WINDOW` =
  fewer, heavier runs. For the six-week `medium` backlog: `WINDOW=3d` ≈ one weekend,
  `WINDOW=1d` ≈ three weekends.
- **Does not bound dataset *count*.** A single unusually dense calendar span (e.g. a
  bulk historical re-extraction dumped on one day) can still pull a large slice even
  at `WINDOW=1d`. Per-batch memory limits and checkpointing contain the blast radius,
  but if pathological density is real, a **count-based cap** (stop after N datasets,
  let per-batch checkpointing carry the position) is the more robust variant. Deferred
  unless profiling shows it is needed; the time window is simpler and matches the
  intended incremental behavior.

## Alternatives considered

- **Full lookback + per-batch checkpoint, no cap** (raised in review — the strongest
  alternative). With ADR 0001, a run already batches the whole lookback, bounds memory
  per batch, and drains incrementally across runs via the checkpoint. It does **not**
  bound the upfront `get_datasets` query or run duration. Whether that matters hinges
  on two unconfirmed facts: **is `diml_es.query_diml_es_index` paginated** (a large
  window could be slow, memory-heavy, or silently truncated), and **what is the Nomad
  allocation's max runtime**. If the query is cheap/paginated and the timeout is
  generous, prefer this — it adds no new knob and ADR 0001 carries the load. If not,
  the cap earns its place. **Resolve these two questions before choosing.**
- **Manually step `lastLoaded` forward in stages** to drain a backlog. A valid
  one-off operational workaround, but not a durable fix — it does not prevent the
  problem recurring.
- **Count-based cap instead of time-based.** More robust against dense windows but
  more complex; deferred (see above).

## Related

- ADR 0001 (per-batch checkpointing) — composes: this prevents most crashes, that
  makes any crash cheap. ADR 0001 is also what delivers incremental cross-run
  progress; this ADR only bounds run size.
- ADR 0002 (contain `start_running` blast radius) — benefits: bounded run duration
  means fewer timeout-driven hard kills that leak the lock.
