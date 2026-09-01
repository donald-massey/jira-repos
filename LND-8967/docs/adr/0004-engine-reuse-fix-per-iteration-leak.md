# ADR 0004: Fix the per-iteration SQLAlchemy engine leak by reusing one instance

- **Status:** Accepted (LND-8967)
- **Date:** 2026-09-01
- **Component:** `diml_loaders/shared/db_connections.py`, all three loaders

## Context

`DatabaseOperations().get_session()` calls `create_engine()` on every invocation, each
producing a fresh engine with its own connection pool. All three loaders call it
**once per loop iteration** with a **newly-constructed instance**:

- `okcountyrecords_loader.py:169` — `DatabaseOperations().get_session()` inside `for dataset in datasets`
- `digitalclerk_loader.py:146` — same
- `iie_loader.py:66` and `:132` — `DatabaseOperations().get_session()` inside the batch loop

Each iteration builds an engine and never disposes it. The pools accumulate, memory
grows every loop, and a long backfill run eventually OOM-kills. (Reported by Ellen D.)

**The leak trigger and the obvious fix miss each other.** LND-8967 proposed caching the
engine on the instance:

```python
def get_session(self):
    if not hasattr(self, '_engine'):
        self._engine = self.to_engine()
    return sessionmaker(bind=self._engine)()
```

This is a **no-op as written**, because the leak is driven by constructing a new
`DatabaseOperations()` each iteration. On a fresh instance `hasattr(self, '_engine')` is
always `False`, so `to_engine()` still runs every time. An instance-scoped cache cannot
help a caller that discards the instance every iteration. This is the surprising part
worth recording: the fix and the leak are at different scopes, so the fix as proposed
would close the card while leaving the leak in place.

## Decision

Keep the instance-level `_engine` cache from the ticket, **and** hoist a single
`DatabaseOperations()` out of each loader's loop, reusing it across iterations:

```python
db = DatabaseOperations()
for dataset in datasets:
    session = db.get_session()   # reuses db._engine after the first call
    ...
```

Now the cache does its job: one engine and one pool per loader run, shared across every
iteration. `main.py`'s two instances (startup query, run session) are left as-is — that
is two engines per process, not a per-iteration leak.

The IIE `ThreadPoolExecutor` (`iie_loader.py:74`) only performs S3 downloads, never DB
work, so a single shared engine/pool on the main thread is safe.

## Consequences

**Positive**
- One engine + pool per loader run; memory stops growing per iteration. Fixes the OOM
  at its source across all three loaders.
- Minimal library change — the `get_session()` cache is the ticket's, plus a one-line
  hoist per loop.

**Negative / accepted trade-offs**
- **Fragile to reintroduction.** The fix depends on callers *not* constructing
  `DatabaseOperations()` inside a loop. A future loop that news-up an instance inside
  itself silently reintroduces the leak, and nothing enforces the discipline.
- A module- or class-level engine singleton would be reintroduction-proof (any instance
  shares the one engine) but was set aside in favor of the smaller, more explicit
  instance-hoist. Revisit the singleton if the leak recurs.

## Alternatives considered

- **Module/class-level engine singleton.** Reintroduction-proof and needs no loader
  edits, but hides a global shared pool behind the constructor. Deferred; preferred
  fallback if the hoist proves fragile.
- **`engine.dispose()` on session close.** Stops accumulation without a shared engine,
  but discards pooling entirely (a fresh pool every iteration = connection churn) and
  needs a `finally`-block edit in every loop. Rejected.

## Related

- ADR 0001 / ADR 0005 reduce how large and long a run gets; this removes the per-loop
  memory growth within a run. Together they close the OOM path from both ends.
