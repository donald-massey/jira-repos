# compare-airflow-dags

Claude Code skill that structurally compares two Airflow DAG files (old vs
ported/migrated) to verify the new one preserves every task and all
functionality of the old one. Built for LND-9071 (abstract_plant migration to
the new Airflow instance).

It parses each DAG statically (AST — no execution, no Airflow install) into an
inventory of tasks, dependency edges, per-task kwargs, expanded `default_args`,
and callable bodies, then reasons about the differences — separating expected
port adjustments (import moves, operator renames, `schedule_interval`→`schedule`)
from real regressions (dropped tasks/edges, lowered retries, changed commands,
removed callbacks). Output is a `dag_comparison.md` report.

## Files
- `SKILL.md` — the skill (workflow + regression-vs-port classification + report template)
- `scripts/extract_dag.py` — standalone AST extractor; `python extract_dag.py <dag.py>` emits JSON
- `evals.json` — trigger/output eval cases

## Install
This is the source copy. To use it as a live skill, sync it to the Claude Code
skills dir:

```
cp -r _tools/compare-airflow-dags ~/.claude/skills/
```

(the installed copy is the source of truth for triggering; edit there and copy
back here to version changes.)
