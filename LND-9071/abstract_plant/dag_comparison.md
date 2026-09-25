# DAG Comparison: old_airflow_dag.py vs new_airflow_dag.py (`abstract_plant`)

## Verdict
⚠️ **Regressions found — no tasks dropped, but real functionality was removed and two re-platformings need verification.**

All **34 tasks are present in both** DAGs and the dependency topology is preserved. However:

- 🔴 **MS Teams notifications were gutted** — all three `notify_*` tasks became no-op `EmptyOperator`s, and the Teams alerts inside `verify_new_counts` were removed. The DAG no longer sends any Teams message on success, failure, upstream-failure, or tolerance warning.
- 🟡 **Elasticsearch pipeline re-platformed** from in-Airflow Python (`es23.*`) to Nomad-dispatched jobs — needs equivalence verification, especially a **1-based → 0-based shard-position change** that could silently drop a shard.
- 🟡 **`MsSqlDDLOperator` → `SQLExecuteQueryOperator`** for all Denodo load/flip/rollback tasks — verify DDL batch/commit semantics and the new explicit `rollback` param.

VictorOps failure alerting (`on_failure_callback=notify_failure_victor_ops`) survives, so on-call paging is intact — but the human-facing Teams messages are gone.

## Regressions & behavior changes
| Severity | Type | Old | New | Impact |
|---|---|---|---|---|
| 🔴 | Notifications removed | `notify_success` / `notify_failure` / `notify_upstream_failure` = `MSTeamsWebhookOperator` posting to `ms_teams_land_notifications` | all three = `EmptyOperator` (no-op) | No Teams message on run success/failure/upstream-failure. Tasks still run (topology intact) but do nothing. |
| 🔴 | Notifications removed | `verify_new_counts` posted Teams messages via `MSTeamsWebhookHook` (`ms_teams_data_delivery`): a "count decreased but within tolerance" warning, and a Teams alert on out-of-tolerance | new version only `raise`s on out-of-tolerance; no Teams messaging at all | The within-tolerance decrease warning is silently gone; out-of-tolerance still fails the run (gate preserved) but no longer notifies Teams. |
| 🟡 | ES shard indexing convention | `for x in range(1, 5)` → `proc_position` = **1,2,3,4** (`proc_count=4`) | `for i in range(LOAD_PROC_COUNT=4)` → `PROC_POSITION` = **0,1,2,3** | If the loader shards by `id % proc_count == proc_position`, the position set must be `0..count-1`. Old ran 1..4, new runs 0..3. **Confirm which convention the Nomad loader uses — a mismatch silently drops one shard of records from the index.** |
| 🟡 | ES operator re-platform | `create_elasticsearch_index`, `flip_elasticsearch`, `cleanup_es_index`, and 4× `load_elastic_search_batch_*` = `PythonOperator` calling `es23.create_index/flip/drop_index/load` | same task_ids as `NomadDispatchOperator` dispatching `elasticsearch-loader_job` (ACTIONs create_index/flip_index/delete_index/load_nested_dataset) | Behavior intended to be equivalent but now runs out-of-process in Nomad. Verify index-name format (`get_index_name` = `index_type-ts_nodash`), create/flip/delete, and that `es_config`/`es_map` payloads match what `es23` produced. |
| 🟡 | DDL operator swap | `load_denodo*`, `flip_dnd*`, `rollback_*` = custom `MsSqlDDLOperator(mssql_conn_id=...)` | `SQLExecuteQueryOperator(conn_id=...)`, flip/load tasks gained explicit `params={'rollback': False}` | Custom DDL operator likely handled `GO` batch splitting / autocommit that `SQLExecuteQueryOperator` does not. Verify the SQL templates execute correctly (multi-batch DDL, commit behavior) and that `{{ params.rollback }}` is consumed by the templates. |
| 🟢 | Topology addition | flip_elasticsearch upstream = `stage_geo_rendering_load` only | also `verify_load_counts >> flip_elasticsearch` added (line 895) | Redundant — `verify_load_counts` is already a transitive ancestor via `stage_geo_rendering_load`. Harmless with default `all_success` trigger rule, but note it's an added direct edge. |
| 🟢 | Catchup | `catchup` not set (inherited instance default) | explicit `catchup=False` | Safe/explicit. Confirm the old instance ran with `catchup_by_default=False` (near-certain given a 2017 start_date + daily schedule); if old had catchup on, new stops backfill. |

## Expected port adjustments (verified equivalent, no action)
- Import moves: `airflow.operators.dummy_operator`→`airflow.operators.empty`; `python_operator`→`python`; `airflow.hooks.mssql_hook`→`providers.microsoft.mssql.hooks.mssql`; `data_ops_dags.*`→`enverus.custom_utils.*`.
- `DummyOperator` → `EmptyOperator` (`join`, `rollback_flip`) — Airflow 2 rename, identical behavior.
- `schedule_interval='0 20 * * *'` → `schedule='0 20 * * *'` — same cadence.
- `mssql_conn_id=` → `conn_id=` — same connection value (`config['denodo']['connection_id']`), required by the new operator.
- `dag_id='abstract_plant'` → `dag_id=DAG_NAME` where `DAG_NAME='abstract_plant'` — same value.
- `email`: `Variable.get('land.emaillist')` inlined → assigned to `land_email_list` first — same value, same Variable.
- `provide_context=True` removals / additions — no effect under Airflow 2 (context always passed).
- New helper functions (`build_es_config`, `build_sql_config`, `get_index_map/name`, `get_indexer_config`, `extend_es_*_meta`, `modify_es_load_config_with_source_tables`) — additions that assemble the Nomad job payloads; they encapsulate work `es23` previously did internally.
- Count-verification callables (`current_state`, `get_nested_count`, `verify_load_counts`, `verify_presentation_counts`, `set_denodo_*`) — bodies refactored (typing, `ti.log` instead of `logging`, fresh `Variable.get`) but logic and the count/branch gates are behavior-preserving. **Exception:** `verify_new_counts` (see regression table).

## Needs manual verification
1. **ES shard positions (highest priority):** confirm the Nomad `elasticsearch-loader_job` expects `PROC_POSITION` 0-based. Old dispatched 1..4; new dispatches 0..3. Wrong convention = one shard of records missing from the index with no error.
2. **DDL execution semantics:** run one Denodo load + flip through `SQLExecuteQueryOperator` and confirm multi-statement/`GO`-delimited templates and commit behavior match the old `MsSqlDDLOperator`.
3. **Deliberate or accidental?** Confirm with the platform team whether replacing the three Teams `notify_*` tasks and the `verify_new_counts` Teams alerts with no-ops was intentional (e.g., Teams retired in favor of VictorOps) or an oversight during the port.
4. **ES index name compatibility:** verify `get_index_name` (`{index_type}-{ts_nodash}`) produces names compatible with the alias-flip and any downstream consumers that were built against the old `es23` naming.
5. **`mark_success` control-table fallback:** new default `'ev_dw_data_sync_control'` (line 676) differs from the documented `ev_ds9_data_sync_control` in the config docstring. Harmless if the Variable supplies the value; confirm it does.

## Coverage
- Tasks: old 34 / new 34 — identical `task_id` set. No task dropped or added.
- Edges: topology equivalent after resolving variable renames (`flip_es_task`→`flip_elasticsearch_task`, `cleanup_elasticsearch_index`→`cleanup_es_index`, etc., all same `task_id`s); one added direct edge (`verify_load_counts → flip_elasticsearch`).
- Dynamic/unresolved: 1 loop each (ES load tasks). Old expands to 4 (`load_elastic_search_batch_1..4`), new to 4 (`load_elastic_search_0..3`) — same count, but position convention changed (see regression #3).
- Operator changes: 20 tasks changed operator class (ES→Nomad, MsSqlDDL→SQLExecuteQuery, Dummy→Empty, MSTeams→Empty).