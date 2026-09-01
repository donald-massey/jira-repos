# ADR 0002: Recover from a leaked `start_running` lock (no schema change)

- **Status:** Proposed
- **Date:** 2026-08-31
- **Component:** `diml_loaders/shared/utils.py` (`start_running`), `dbo.loaderStatus`

## Context

Each `loaderStatus` row carries a `running` boolean that acts as a
mutual-exclusion lock: a run sets it `true` at start and `false` at end, and refuses
to start if it is already `true`. The flag is released in `main.py`'s `finally`
block, which is **not crash-safe**: a hard kill — OOM `SIGKILL`, Nomad
timeout/force-stop, node death — terminates the process without running `finally`,
leaving `running` stuck `true`. (Normal Python exceptions *are* handled; only
uncatchable termination leaks the lock.)

For IIE, `start_running` checks **all** priority rows
(`loader_id LIKE 'iie_diml_loader%'`) and refuses to start if *any* is `running`. So
one leaked lock blocks **all three** priorities, not just the crashed one.

This was observed in production: `iie_diml_loader-medium` was left `running = true`
with a six-week-stale `lastLoaded` after an OOM. The wildcard check then blocked
`high` and `low` as well — a single leaked lock became a full IIE outage.

**The wildcard is intentional, not a regression.** `git log -L :start_running:` shows
the function was created with the group-check (commit `f2e3dcd`, *LND-6284: add
graceful exit when loader is running*), and its docstring states the intent
explicitly: *"the IIE loader … has multiple priority levels that could be triggered to
run at the same time. If any of the priority levels are running, the loader should not
start."* So the policy — **only one IIE priority runs at a time** — is deliberate. The
defect is not the wildcard itself; it is that a **stale** lock is indistinguishable
from a **live** one, so a dead run blocks live ones forever.

A self-healing timestamp lease (heartbeat column, reclaim stale locks on startup) was
considered and set aside: it requires modifying `dbo.loaderStatus`, which is out of
scope for this effort.

## Decision

**Contingent on the open question below** — the finding that one-at-a-time is a
deliberate policy splits this into two candidate directions:

- **Direction A — fix the real defect (staleness), keep the policy.** Before honoring
  a `running = true` lock, have `start_running` check whether a `diml_loaders` alloc
  is *actually* live in Nomad. If none is running, the lock is stale: reclaim it and
  proceed. This self-heals a leaked lock, preserves the one-at-a-time policy, and
  needs no schema change — at the cost of coupling `start_running` to the Nomad API.
- **Direction B — reduce blast radius, relax the policy.** Narrow the wildcard to
  per-priority mutual exclusion so a leaked lock pauses only the crashed priority.
  One-line change, no schema, no Nomad coupling — but it *does not self-heal* (manual
  reset still needed) and it **overrides the deliberate one-at-a-time policy**, so it
  is only acceptable once that policy's rationale (open question) is known to be safe
  to relax.

Direction A addresses the root cause (stale ≠ live); Direction B only limits damage.
A is preferred if the Nomad coupling is acceptable; B is the fallback if it is not and
the policy turns out to be safely relaxable. Both compose with ADR 0001 and 0003,
which make the leaking hard kills rare in the first place.

## Open question (resolve before implementing)

The history question is answered: the wildcard is deliberate (LND-6284). The
remaining question is **why one-at-a-time was chosen**, because that decides whether
narrowing is even acceptable:

- **Resource contention** — all priorities dispatch the same `diml_loaders` Nomad
  job; the author may have wanted one IIE run's memory/DB footprint at a time. If so,
  narrowing trades the outage risk for concurrent resource pressure.
- **Dedup race** — dedup is a `package_id` query-check with **no unique constraint**
  (confirmed: `InstrumentExtraction.package_id` is a plain column). If two priorities
  can ever process the same `package_id` concurrently, narrowing risks double-inserts.

LND-6284's ticket/PR should say which. Until it does, **narrowing is not a safe
one-liner** — it relaxes a documented policy.

## Consequences

**Direction A (Nomad liveness check)**
- Self-heals a leaked lock automatically on the next run; no manual reset.
- Preserves the deliberate one-at-a-time policy; no schema change.
- Couples `start_running` to the Nomad API — a new external dependency in the
  startup path, and a failure mode of its own (Nomad unreachable → how to fail?).

**Direction B (narrow the wildcard)**
- Blast radius contained to a single priority; no schema change; one-line change; no
  Nomad coupling.
- Does **not** self-heal — the crashed priority still needs manual reconciliation.
- **Overrides the one-at-a-time policy** and permits concurrent cross-priority runs.
  Safe only if priorities are genuinely disjoint by `package_id` (no unique
  constraint exists to catch a collision); otherwise a dedup race can double-insert.
  This is the crux of the open question.

## Alternatives considered

- **Heartbeat / timestamp lease (self-healing).** The cleanest staleness fix, but
  requires a schema change to `dbo.loaderStatus`. Out of scope for this effort;
  Direction A achieves the same self-healing without the column by asking Nomad
  instead of a stored timestamp. Revisit if the Nomad coupling proves worse than a
  migration.
- **Startup self-heal of the same-priority flag only.** Airflow `max_active_runs=1`
  guarantees no concurrent same-priority run, so a starting run could safely clear its
  own stale flag — but under the wildcard it would not unblock sibling priorities, so
  it only helps combined with Direction B.
- **Do nothing; rely on 0001/0003 to make crashes rare, reconcile manually.**
  Leaves the full-outage blast radius in place for every future hard kill.

## Related

- ADR 0001 and ADR 0005 reduce the frequency of the hard kills that leak the lock.
- [`../monitoring/loaderstatus-sla.md`](../monitoring/loaderstatus-sla.md) — the
  detection counterpart: this ADR *contains* a leaked lock, monitoring *surfaces* it.
