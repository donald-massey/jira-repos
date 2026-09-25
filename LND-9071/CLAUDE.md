# LND-9071

Verify Airflow DAGs ported to the new Airflow instance didn't lose any tasks or
functionality versus the old instance. The platform team rewrote the DAGs for the
new instance; logs were already checked, so this workspace does an in-depth
**structural** comparison (not a line diff) to confirm nothing was dropped.

## Layout

```
LND-9071/
├── old_airflow_dag.py          # original DAG (old Airflow instance) — source of truth
├── new_airflow_dag.py          # ported DAG (new instance) — the version being verified
└── <dag_id>/                   # one folder per DAG compared, named after its dag_id
    └── dag_comparison.md       # the comparison report
```

Current comparison: **`abstract_plant`** — see `abstract_plant/dag_comparison.md`.
To compare another DAG, drop its two versions in as `old_airflow_dag.py` /
`new_airflow_dag.py` (or a clearly-named pair) and re-run; the report lands in a new
`<dag_id>/` folder.

## The comparison skill

The work is driven by the **`compare-airflow-dags`** skill, which lives in this repo
at `.claude/skills/compare-airflow-dags/` (a project skill — Claude Code auto-loads it
when working anywhere in jira-repos; there is no global copy). It extracts a structured
inventory from each DAG, reasons about the differences, and separates expected port
adjustments (import moves, operator renames, `schedule_interval`→`schedule`) from real
regressions (dropped tasks/edges, lowered retries, changed commands, removed callbacks).

**To run it**, just ask Claude in natural language, e.g.:

> compare old_airflow_dag.py and new_airflow_dag.py — make sure the new one didn't drop
> any tasks or functionality

The skill writes the report to `<dag_id>/dag_comparison.md`. Its verdict is one of
✅ no gaps / ⚠️ regressions found / ❓ cannot fully verify statically.

## Running the extractor directly

The skill bundles a standalone AST extractor you can run without Claude. It parses a
DAG statically — no execution, no Airflow install, no resolving the DAG's imports — so
it works on source from any Airflow version:

```bash
python .claude/skills/compare-airflow-dags/scripts/extract_dag.py <dag_file.py>
```

It prints JSON with: `dag` (dag_id, schedule, catchup, expanded `default_args`, tags),
`tasks` (task_id + operator + every kwarg), `edges` (dependency graph, list operands
resolved to task_ids), `functions` (module-level def source, for diffing
`python_callable` bodies), `dicts`, `dynamic` (tasks built in loops — cannot be fully
enumerated statically), and `warnings`.

Run it on both files and diff the two JSON inventories to see task/edge/config/callable
changes. The skill's `SKILL.md` documents the full workflow and the
regression-vs-port classification rules.

## Notes

- **Dynamic tasks** (built in `for` loops or by factory functions) can't be enumerated
  statically — the extractor flags them in `dynamic`/`warnings` and the report routes
  them to manual verification. Never claim "no gaps" when these are present.
- The extractor renders arg values as source strings, so a quoting/formatting-only
  difference is not a behavior change — compare meaning, not the exact string.