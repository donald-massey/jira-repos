# ADR 0001: Per-batch checkpointing for the IIE loader

- **Status:** Proposed
- **Date:** 2026-08-31
- **Component:** `diml_loaders/iie/iie_loader.py`, `main.py`, `dbo.loaderStatus`

## Context

The IIE loader processes a *window* of datasets (from `lastLoaded` minus a one-day
overlap, up to the run's end bound) in *batches*. Today `lastLoaded` is advanced
**once, at the very end** of a successful run.

For the historical priorities (`medium`, `low`) a window can span weeks. When a run
fails partway — most often an OOM kill — `lastLoaded` is never advanced, so the next
run retries the **entire window from scratch**, hits the same wall, and fails again.
Progress made before the crash is thrown away, and the loader can get stuck in a
failure loop that never drains the backlog.

Three properties of the existing design make incremental progress safe to persist:

- Datasets are returned **sorted by `created_at` ascending** and processed in that
  order, so the maximum `created_at` of a committed batch is a valid watermark.
- Deduplication is by **`package_id`**, so re-querying an overlapping window and
  re-encountering already-written packages is a no-op.
- The window deliberately starts one day **before** `lastLoaded` to absorb
  Elasticsearch indexing lag, giving re-queries a built-in overlap.

## Decision

Advance `lastLoaded` **per batch** rather than once per run. After a batch commits,
set the checkpoint to that batch's maximum dataset `created_at`, written **in the
same database transaction as the batch's extractions** so data and progress commit
atomically.

A crash mid-run therefore leaves `lastLoaded` at the last durably-committed batch.
The next run resumes from there (minus the overlap), and `package_id` dedup absorbs
the re-queried overlap.

The end-of-run finalize (advancing `lastLoaded` to the window's end bound on full
success) is retained; it covers any trailing span of the window that contained no
datasets.

## Consequences

**Positive**
- A crash costs one batch of rework, not an entire window. The backlog drains
  monotonically instead of looping.
- Checkpoint and data are atomic; the checkpoint can never move past data that
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

- ADR 0003 (per-run window cap) bounds how large a window a run attempts;
  it and this decision compose — the cap prevents most crashes, this makes any crash
  cheap to recover from.
