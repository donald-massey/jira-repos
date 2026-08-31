# Monitoring proposal: `loaderStatus` health on the Land SLA dashboard

- **Status:** Proposed
- **Target:** Redash dashboard 119 — *Land Data Engineering SLA — Land Overview*
  (`http://redash.enverus.com/dashboards/119-land-data-engineering-sla-land-overview`)
- **Source:** `dbo.loaderStatus` (CS Digital database)

## Motivation

The six-week `iie_diml_loader-medium` outage went unnoticed because **nothing
watches `loaderStatus`**. ADR 0002 contains the blast radius of a leaked lock and
ADR 0001/0003 make crashes rarer, but none of them *surface* a stall. Detection is
the missing layer: a stuck lock or a checkpoint that stops advancing should be
visible on the SLA board within a day, not discovered by hand weeks later.

## Health signal: advancement vs. age

An absolute-age alert (`now() - lastLoaded > N`) is **wrong for the backfill
priorities**. `medium` and `low` are *expected* to be weeks behind while draining, so
an age threshold leaves them permanently red — the board gets ignored, defeating the
purpose. The signal that separates "healthy backfill" from "stuck backfill" is
**whether `lastLoaded` advanced**, not how old it is: a draining loader moves its
checkpoint every run; a wedged one does not, regardless of absolute age.

This splits the loaders into two different checks:

| Loader | Cadence | Correct health check |
|--------|---------|----------------------|
| `iie_diml_loader-high`, other daily loaders | Daily | **Absolute freshness** — `now() - lastLoaded < ~1 day` |
| `iie_diml_loader-medium`, `iie_diml_loader-low` | Backfill | **Advancement** — did `lastLoaded` move run-over-run? Absolute age is not a breach signal. |

## Proposed widgets

1. **Stuck-lock detector** *(lead widget)* — rows where `running = 1` **and**
   `lastLoaded` is older than a max-expected-runtime threshold. This is the exact
   condition that caused the outage: a run that set the lock, died, and never cleared
   it. It does double duty — it flags both a **leaked lock** and a **wedged backfill**
   — and needs no history, only the current row. This is the alarm that would have
   fired on day one.

2. **Loader freshness (daily loaders)** — `now() - lastLoaded` per `loader_id`, with
   an absolute-age threshold. Meaningful only for the daily cadence (`high` and the
   non-IIE loaders); do **not** apply an age threshold to `medium` / `low`.

3. **Checkpoint advancement (backfill priorities)** — did `lastLoaded` move since the
   previous run? Redash cannot see "the previous run" from the current row alone, so
   this needs one of: a periodic **snapshot history** of `loaderStatus` (table +
   scheduled capture) to diff against, or reliance on widget #1 as the practical proxy
   (a non-advancing backfill is almost always sitting under `running = 1`). Prefer the
   snapshot only if #1 proves insufficient.

## Open questions

- **Data source (blocker).** Does the Redash instance behind dashboard 119 already
  have a connection to CS Digital / `dbo.loaderStatus`? If not, that connection must be
  provisioned before any widget can be built. Step zero.
- **Max-expected-runtime threshold** for the stuck-lock detector (widget #1). This
  number is only meaningful once ADR 0003 bounds run duration — before that, "how long
  should a run take" is unbounded. Sets the `lastLoaded`-age cutoff paired with
  `running = 1`.
- **Daily-freshness threshold** for widget #2 (`high` and non-IIE loaders) — ~1 day is
  the starting assumption; confirm against each loader's actual cadence.

## Relationship to the ADRs

Detection counterpart to **ADR 0002**: 0002 *contains* a leaked lock to one priority;
this *surfaces* it so it gets reconciled promptly. Together they close the gap that
turned one crash into a six-week outage.
