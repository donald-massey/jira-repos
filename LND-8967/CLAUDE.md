# LND-8967: Refactor Courthouse-MFG: IIE Incremental Checkpoint, Max Batch Config & Increase Memory

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8967
**Status:** In Progress

`courthouse-mfg` currently runs until exhaustion with no per-run batch limit and commits only at end-of-run, meaning a mid-run crash requires a full restart. A SQLAlchemy engine-per-call leak in the OKCR and DigitalClerk loaders compounds memory pressure on every loop iteration. This card adds two Consul-KV-controlled limits, increases `NOMAD_MEM`, and fixes the engine leak in `db_connections.py`.

### Current Problem

1. **No incremental commit:** Results are committed only at end-of-run — a mid-run crash loses all progress and requires a full restart from scratch.
2. **No per-run batch cap:** The process runs until exhaustion with no configurable upper limit on how many batches execute per invocation.
3. **Under-provisioned memory:** `NOMAD_MEM` is below what the expanded workload requires.
4. **SQLAlchemy engine leak causing OOM:** `DatabaseOperations().get_session()` creates a brand-new SQLAlchemy engine and connection pool on every call. In the OKCR and DigitalClerk loaders this is called once per dataset inside a loop — each iteration leaks the engine from the previous iteration, steadily growing memory until the process is killed. (Suggestion From Ellen D.)

### Proposed Improvement

1. The process commits its results after every 10 batches, regardless of run completion.
2. A new Consul-KV variable `IIE_MAX_BATCHES` is added and set to `400`, capping the number of batches processed per invocation.
3. `NOMAD_MEM` updated to `24576` (24 GB) in Consul-KV.
4. `db_connections.py` is updated to cache the engine on the `DatabaseOperations` instance so repeated `get_session()` calls reuse the same engine and connection pool:

```python
def get_session(self):
    if not hasattr(self, '_engine'):
        self._engine = self.to_engine()
    Session = sessionmaker(bind=self._engine)
    return Session()
```

### Definition of Done

* Process commits results after every 10 batches processed
* `IIE_MAX_BATCHES` Consul-KV key added, set to `400`, and wired into the run loop in dev and prod
* `NOMAD_MEM` Consul-KV value updated to `24576` in dev and prod
* MyGlue entry updated to reflect `NOMAD_MEM` and `IIE_MAX_BATCHES`
* `db_connections.py` engine caching fix applied; OKCR and DigitalClerk loaders verified to no longer leak engines per iteration
* Deployed to dev and validated
* Promoted to prod

### Risk if Deferred

A mid-run crash loses all progress; uncapped runs consume unbounded resources; the engine-per-call leak causes OOM termination on any sufficiently large dataset run.

## Approach

Resolved in the 2026-09-01 grill session. Design docs live in this folder:
`CONTEXT.md` + `docs/adr/` (see `docs/adr/README.md`). The LND-8967 decisions are
ADR 0001 (checkpointing), 0004 (engine fix), 0005 (batch cap); ADR 0002 and
`docs/monitoring/` are the broader diml-loaders effort, parked here. Code under
refactor: `C:\Users\donald.massey\PycharmProjects\diml-loaders`.

**Scope note — loaderStatus stays.** An earlier card title read "...and Remove
loaderStatus"; the title has since been corrected to "IIE Incremental Checkpoint, Max
Batch Config & Increase Memory". `loaderStatus` is retained — the ADRs depend on it as
the run lock + checkpoint store.

1. **Engine leak fix (ADR 0004).** The ticket's instance-level `_engine` cache is a
   no-op as written — every loader news-up `DatabaseOperations()` per iteration, so the
   cache never hits. Fix: keep the cache **and hoist one `DatabaseOperations()` out of
   each loop**, reusing it. Touches `okcountyrecords_loader.py:169`,
   `digitalclerk_loader.py:146`, `iie_loader.py:66`/`:132`. `main.py`'s two instances
   left as-is (2 engines/process, not a per-iteration leak). Risk: a future loop that
   news-up inside itself reintroduces the leak.

2. **Periodic checkpointing (ADR 0001, revised).** IIE only. Switch the watermark to
   each batch's max `created_at` and advance `lastLoaded` **every 10th batch** to the
   max `created_at` of the last *fully-committed* batch. Keep the end-of-run finalize to
   `this_load_date` for the trailing empty span — **except** on a capped run (see #3).
   OKCR/DigitalClerk are not batched; they keep their end-of-run checkpoint.

3. **`IIE_MAX_BATCHES=400` per-run cap (ADR 0005).** IIE only. Break the batch loop at
   400 batches (counts batches *attempted*, not new-data batches). On a capped stop,
   **skip the finalize** so `lastLoaded` stays at the last committed batch and the next
   run resumes — requires the loader to signal "capped" back to `main.py`. Add the key
   to Consul KV, dev + prod.

4. **`NOMAD_MEM=24576`** (24 GB) in Consul KV, dev + prod.

5. **Ops:** MyGlue entry updated for `NOMAD_MEM` and `IIE_MAX_BATCHES`; verify Consul-KV
   changes before each deploy; deploy to dev + validate, then promote to prod.

## Completed

<!-- Updated as work is finished -->
- 2026-09-01: Workspace bootstrapped; grill session resolved all 4 body items;
  CONTEXT.md + ADR 0001/0004/0005 written. Consolidated all planning docs from the
  old `diml-loaders-plan/` into this folder and deleted it; renumbered the batch-cap
  ADR to 0005 to resolve a collision with the pre-existing window-cap ADR 0003.
- 2026-09-01: Card title reconciled (no "Remove loaderStatus"); scope note updated.
- 2026-09-01: Code changes implemented on branch `LND-8967` in `diml-loaders`:
  * `db_connections.py` — instance `_engine` cache in `get_session()` (ADR 0004).
  * `okcountyrecords_loader.py` / `digitalclerk_loader.py` — hoisted one
    `DatabaseOperations()` above each loop so the cache actually hits (ADR 0004).
  * `iie_loader.py` — engine hoist; `IIE_MAX_BATCHES` cap (default 400) with
    `capped` return (ADR 0005); every-10-batch checkpoint to last batch's max
    `created_at`, restructured `continue` skips to nested if/else (ADR 0001).
  * `main.py` — capture loader return; skip finalize when `capped`.
  * `tests/test_iie.py` — added cap + checkpoint tests; fixed env gap in existing
    batch test. New loader tests pass (3/3). Remaining suite failures are all
    pre-existing (missing env vars / data-format drift), confirmed via git stash.
  Still open (ops, external): Consul KV `IIE_MAX_BATCHES=400` + `NOMAD_MEM=24576`
  in dev+prod; MyGlue entry; deploy+validate dev then prod.
