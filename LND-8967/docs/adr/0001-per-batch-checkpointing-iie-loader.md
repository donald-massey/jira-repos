# ADR 0001: Periodic (every-10-batch) checkpointing for the IIE loader

- **Status:** Accepted (LND-8967)
- **Date:** 2026-08-31 (revised 2026-09-01)
- **Component:** `diml_loaders/iie/iie_loader.py`, `main.py`, `dbo.loaderStatus`

## Context

The IIE loader processes a *window* of datasets (from `lastLoaded` minus a one-day
overlap, up to the run's end bound) in *batches*. Each batch commits its own
extractions on its own session **inside the loop** (`iie_loader.py:66`, `:128`), so
batch data is durable as the run proceeds. What is advanced **once, at the very end**
of a successful run is the checkpoint — `lastLoaded` — on a *separate* session in
`main.py:21`–`:22`.

The distinction is the whole point. When a run fails partway — most often an OOM kill —
the batch rows already committed **survive**; what is lost is only the `lastLoaded`
watermark, which never advanced. For the historical priorities (`medium`, `low`) a
window can span weeks, so the next run re-queries the **entire window from scratch**
against the stale watermark. It does not double-insert — `package_id` dedup
(`iie_loader.py:95`) skips the rows already written — but it re-does all the ES query,
S3 download, and dedup-check work, hits the same memory wall, and fails again. The
*data* is not thrown away; the *position* is, and the loader gets stuck in a failure
loop that never drains the backlog.

Three properties of the existing design make incremental progress safe to persist:

- Datasets are returned **sorted by `created_at` ascending** and processed in that
  order, so the maximum `created_at` of a committed batch is a valid watermark.
- Deduplication is by **`package_id`**, so re-querying an overlapping window and
  re-encountering already-written packages is a no-op.
- The window deliberately starts one day **before** `lastLoaded` to absorb
  Elasticsearch indexing lag, giving re-queries a built-in overlap.

## Decision

Advance `lastLoaded` **every tenth batch** rather than once per run. The checkpoint is
set to the maximum dataset `created_at` of the **last fully-committed** batch — never
an in-flight one — and is written **in a committed transaction** so the checkpoint can
never move past data that did not persist.

A crash mid-run therefore leaves `lastLoaded` at the last checkpointed batch boundary
(at most nine un-checkpointed batches behind). The next run resumes from there (minus
the overlap), and `package_id` dedup absorbs the re-queried overlap — so the at-most-10
batches of re-work are no-ops, not double-inserts.

**Cadence — why 10, not 1.** Per-batch (every-1) minimizes worst-case rework to a
single batch, but writes a checkpoint on every batch. Every-10 caps rework at ten
batches while cutting checkpoint writes 10×. Since `package_id` dedup makes re-work
cheap and idempotent, the marginal safety of every-1 does not justify the extra write
traffic; **10** is the chosen cadence (`LND-8967`, item #1).

The end-of-run finalize (advancing `lastLoaded` to the window's end bound on full
success) is retained for the normal completion path; it covers any trailing span of
the window that contained no datasets. **Exception:** when a run stops at the batch cap
(ADR 0005) the finalize is skipped — the tail past the last committed batch is
unprocessed and must not be checkpointed over. This makes the loader, not `main.py`,
the owner of the IIE checkpoint on the capped path (see ADR 0005).

## Consequences

**Positive**
- A crash costs at most ten batches of *rework* (re-query/re-download, absorbed as
  dedup no-ops), not an entire window. The backlog drains monotonically instead of
  looping.
- The checkpoint is written in a committed transaction and only ever set to the max
  `created_at` of an already-committed batch, so it can never move past data that
  didn't persist.

**Negative / accepted trade-offs**
- **Couples the loader to `loaderStatus`.** Previously only `main.py` wrote
  `lastLoaded`; the loader owned no control state. The loader must now know its
  `priority_loader_id` and write the checkpoint. This is a deliberate break in
  separation of concerns, justified by atomicity — the checkpoint must ride in the
  batch's transaction, which only the loader holds.
- **Download-failure gap (deferred follow-up).** A dataset whose S3 download or parse
  *fails* is currently indistinguishable from one that is legitimately *empty* — both
  simply drop out of the batch. Advancing the checkpoint to the batch maximum
  therefore skips a failed dataset permanently, since later runs only query
  `> lastLoaded`. This is **pre-existing behavior** (the end-of-run finalize already
  skipped failed downloads); per-batch checkpointing neither introduces nor worsens
  it, but it is the natural place to fix it. Fixing it means distinguishing
  error-from-empty, freezing the checkpoint on any batch that had a failure, and
  guarding the end-of-run finalize so it does not re-advance past the gap — a change
  to the loader↔`main.py` contract shared by all three loaders, deferred to its own
  decision.

## Alternatives considered

- **Keep end-of-run-only checkpointing, rely on retries.** Rejected: does not stop
  the failure loop; every retry re-attempts the full window.
- **Commit per dataset instead of per batch.** Rejected: loses the batched dedup
  query and batch-commit efficiency for a marginal reduction in worst-case rework.

## Related

- ADR 0005 (per-run batch cap, `IIE_MAX_BATCHES`) bounds how many batches a run
  attempts; it and this decision compose — the cap prevents most crashes, this makes
  any crash cheap to recover from. It is what LND-8967 implements.
- ADR 0003 (per-run *window* cap) is the deferred time-based alternative to 0005;
  both aim to bound run size, and this checkpoint composes with either.
