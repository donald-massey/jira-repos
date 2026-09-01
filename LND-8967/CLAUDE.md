# LND-8967: Refactor Courthouse-MFG: IIE Priority Datasets, Batch Config, and Remove loaderStatus

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

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
