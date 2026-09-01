# ADR 0005: Per-run batch cap for the IIE loader (`IIE_MAX_BATCHES`)

- **Status:** Accepted (LND-8967)
- **Date:** 2026-09-01
- **Component:** `diml_loaders/iie/iie_loader.py`, `main.py`, Consul KV
- **Supersedes:** the count-based-cap variant that ADR 0003 (per-run *window* cap)
  deferred. LND-8967 chose the count-based cap (this ADR) over the time-window cap;
  ADR 0003 is left **deferred**, not implemented.

> **Residual gap vs. ADR 0003.** `IIE_MAX_BATCHES` caps datasets *processed*, but
> `iie_loader.py` calls `get_datasets` to materialize the **entire window's** metadata
> *before* the batch loop runs — so the upfront ES query and its memory are **not**
> bounded by this cap (that was ADR 0003's specific target). Accepted because dataset
> *metadata* is small next to the S3 result files and extractions the batch loop holds.
> If the upfront query itself proves heavy (large/unpaginated `query_diml_es_index`),
> revisit the ADR 0003 time-window cap to bound it — the two caps are complementary,
> not mutually exclusive.

## Context

The IIE loader runs until its window is exhausted, with no upper bound on how many
batches a single invocation processes. For the daily `high` priority the window is
small, but the backfill priorities (`medium`, `low`) can span weeks — a single run may
attempt tens of thousands of datasets. A run that large holds memory and DB pressure
for hours and is exactly the kind of run that OOM-kills partway (the failure ADR 0001
and ADR 0002 both trace back to).

ADR 0001 makes *any* crash cheap to recover from (at most ten batches of rework). This
ADR attacks the other half: stop the run from getting large enough to crash in the
first place, by bounding how much one invocation attempts.

## Decision

Add a Consul-KV variable **`IIE_MAX_BATCHES`**, set to **`100`** in dev and prod. At the
Consul `IIE_BATCH_SIZE=100`, that is a **10,000-dataset ceiling per run**. (The code
fallback is also `100`; Consul always sets it explicitly.) The IIE batch loop breaks
once it has processed `IIE_MAX_BATCHES` batches:

```python
for i, start in enumerate(range(0, len(datasets), batch_size)):
    if i >= IIE_MAX_BATCHES:
        capped = True
        break
    ...
```

**The cap counts batches attempted, not batches that wrote new data.** A batch whose
datasets were all already-loaded (dedup skip) still counts. This keeps a run's ES/S3/DB
work — and therefore its runtime and memory ceiling — predictable, which is the point
of the cap. The alternative (count only new-data batches) was rejected: it makes
runtime unbounded again whenever a window has heavy dedup overlap.

**Composition with the checkpoint (ADR 0001).** A capped run is *not* an error and
*not* a full drain — it is one monotonic slice. Because the every-10-batch checkpoint
has already advanced `lastLoaded` to the last committed batch's max `created_at`, the
next scheduled run resumes exactly where this one stopped. The backlog drains in
400-batch slices across successive runs.

**Capped runs must skip the finalize.** `main.py` today unconditionally calls
`set_last_loaded_date(this_load_date, …)` after the loader returns, advancing the
checkpoint to the run's *end bound*. On a capped run that would jump `lastLoaded` past
every unprocessed dataset in the tail — silent data loss. So the loader signals that it
stopped at the cap, and `main.py` skips the finalize on that path. On the capped path
the loader owns the checkpoint entirely; the finalize only runs on genuine
window-exhaustion. This is a deliberate change to the loader ↔ `main.py` contract,
scoped to IIE.

## Consequences

**Positive**
- Bounds a single run's memory and wall-clock, removing the primary trigger for the
  OOM kills that leak locks (ADR 0002) and waste windows (ADR 0001).
- Backfill drains predictably: `ceil(backlog / (IIE_MAX_BATCHES × IIE_BATCH_SIZE))`
  runs to catch up, tunable by the Consul-KV value without a deploy.

**Negative / accepted trade-offs**
- Extends the loader ↔ `main.py` checkpoint contract (capped ⇒ loader owns finalize).
  This is the same coupling ADR 0001 already introduced, taken one step further.
- A mis-set cap (too low) slows the drain; too high re-opens the OOM risk. The value
  lives in Consul KV so it can be tuned per environment.

## Alternatives considered

- **Count only new-data batches toward the cap.** Rejected: makes runtime unbounded
  under heavy dedup overlap, defeating the predictability the cap exists to provide.
- **Hard-fail when the window exceeds the cap.** Rejected: the backfill priorities are
  *expected* to be weeks deep; treating depth as an error would keep them permanently
  red and demand manual intervention on every run.
- **`IIE_MAX_BATCHES=400` (≈2.5h runs).** Considered — one 40k-dataset run drains the
  largest observed backlog (32,671 datasets, one complete `high` run seen in prod logs)
  in a single invocation. Rejected as the initial value because at `IIE_BATCH_SIZE=100`
  the cross-priority `loaderStatus` lock (`start_running` blocks on `iie_diml_loader%`,
  so any priority blocks all others) would be held ~2.5h, starving the daily `high`
  update. Prod logs show ~17s/batch median (p90 24s), so `100` batches ≈ a 40-minute run
  that fits the weekend hourly cadence. Value lives in Consul KV — raise it later if a
  longer single-run drain is preferred and lock contention proves acceptable.

## Related

- ADR 0001 — the every-10-batch checkpoint that makes a capped partial drain resumable.
- ADR 0002 — the leaked-lock recovery; this ADR reduces how often the leaking hard
  kills happen at all.
- `NOMAD_MEM` is raised to `24576` (24 GB) alongside this cap (LND-8967); the two are
  complementary — more headroom per run, and a ceiling on how much any run consumes.
