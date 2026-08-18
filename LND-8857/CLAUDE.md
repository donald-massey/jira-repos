# LND-8857: Convert Landtracs Geom Update Job to Databricks Asset Bundle

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8857
**Status:** In Progress

## Summary

The `land.landtracs-geom-update-spark` Databricks job runs under a personal user account on a manually-configured cluster, creating a single-person dependency with no reproducible deploy. Converting it to a Databricks Asset Bundle (DAB) deployed via GitHub Actions under `sp-ea-land-power-user` (already exists) removes that dependency and aligns it with the team's standard pattern (courthouse-land-data-loader, LLandMan-upstream).

## Current Problem

The job runs as a personal user on a hand-built Databricks cluster — not team-owned, not reproducible from source, and no CI/CD pipeline exists to deploy or version the job config. If that user's Databricks permissions change, the job breaks or becomes unrecoverable.

## Proposed Improvement

Create a DAB (`databricks.yml` + `resources/landtracs-geom-update.job.yml`) modeled on `land.courthouse-land-data-loader` or `land.LLandMan-upstream`. The job will run as `sp-ea-land-power-user` on a policy-governed cluster. GitHub Actions workflows (`deploy_to_dev.yml`, `on_release.yml`) handle dev and prod deployment, pulling SP credentials from Vault at `enverus-ea/databricks/sp-ea-land-power-user`.

## Definition of Done

- [ ] `databricks.yml` created with `run_as: sp-ea-land-power-user` in the prod target
- [ ] `resources/landtracs-geom-update.job.yml` defines the job cluster and task config
- [ ] `deploy_to_dev.yml` GitHub Action deploys to dev on manual trigger
- [ ] `on_release.yml` GitHub Action deploys to prod on release
- [ ] Job verified running as service principal in dev and prod
- [ ] Old manually-configured job decommissioned

## Risk if Deferred

Personal-user ownership means the job breaks or loses access if that user's Databricks permissions change. The job remains non-reproducible and outside standard team operational patterns.

## Approach

### Decisions

- **Task type:** `notebook_task` — preserves existing notebook code as-is, no refactoring of `dbutils.widgets.get()` or cell structure.
- **ODBC Driver 18:** Add a `%sh` cell at the top of the notebook to `apt-get install -y msodbcsql18`. The existing cluster had it pre-installed; DAB clusters start clean. SINGLE_USER under `job-cluster-policy-aws-s3-adl-v1` has root + open egress to packages.microsoft.com, so this works in-cell with no init script.
- **Environment parameter:** Passed via `base_parameters: { Environment: "${var.env}" }` in the notebook task config. The notebook reads it via `dbutils.widgets.get("Environment")`.
- **Schedule:** Define a Quartz cron schedule in the job YAML with `pause_status: PAUSED`. Airflow remains the primary trigger; the schedule can be unpaused for standalone runs.
- **CI/CD:** Validate + deploy only — no Docker, no unit test step. `deploy_to_dev.yml` fires on manual trigger; `on_release.yml` fires on GitHub release publish.
- **Libraries (from existing cluster):**
  - `elm-utils>=1.0.11,<2.0.0`
  - `folium==0.14.0`
  - `geopandas==0.13.0`
  - `sqlalchemy==1.4.45`
  - `pyodbc==4.0.39`
  - `shapely`, `pyproj`, `pandas` are transitive deps of geopandas — no separate pins needed.
- **Cluster spec:** SINGLE_USER, policy `job-cluster-policy-aws-s3-adl-v1`, Spark 14.3.x-scala2.12, `c6gd.2xlarge` (match reference), 4 workers to cover 8 `foreachPartition` partitions.
- **Old job:** Decommissioned manually by owner after verifying the DAB job runs correctly in prod.

### Files to Create

```
databricks.yml                          ← bundle definition, targets dev + prod
resources/
  landtracs-geom-update.job.yml         ← notebook_task, cluster config, libraries, schedule (paused)
.github/
  workflows/
    deploy_to_dev.yml                   ← manual trigger: validate + deploy to dev
    on_release.yml                      ← on release: deploy to prod
```

### Notebook Change

Add one cell at the top of `land.landtracs-geom-update-spark.py` (after the markdown header, before imports):

```python
# COMMAND ----------
# MAGIC %sh
# Install ODBC Driver 18 required for pyodbc SQL Server connections
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
curl -fsSL https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
apt-get update && ACCEPT_EULA=Y apt-get install -y msodbcsql18
```

## Completed

Work lives in the `land.landtracs-geom-update-spark` repo (default branch `master`, not `main`), branch `LND-8857`. PR: https://github.com/enverus-ea/land.landtracs-geom-update-spark/pull/7 (base `master`).

Committed in `617f363`:

- `databricks.yml` — bundle `landtracs_geom_update`, dev (default) + prod targets, `run_as: sp-ea-land-power-user` in prod, SP/policy/instance-profile lookups mirroring courthouse-land-data-loader.
- `resources/landtracs-geom-update.job.yml` — single `notebook_task` → `../land.landtracs-geom-update-spark.py`, `base_parameters: { Environment: "${var.env}" }`, SINGLE_USER `c6gd.2xlarge`×4 cluster on `job-cluster-policy-aws-s3-adl-v1`, the 5 pinned pip libs, Vault + `PIP_INDEX_URL` spark env vars, PAUSED 6 AM cron (Airflow stays primary trigger).
- `.github/workflows/deploy_to_dev.yml` — `workflow_dispatch`, validate → deploy to dev. No Docker/unit-test stage (single notebook, no wheel).
- `.github/workflows/on_release.yml` — on release publish, `databricks bundle deploy -t prod`.
- Notebook — added `%sh` cell installing `msodbcsql18` (pyodbc/`sqlalchemy_connection` path; JDBC driver for `spark_connection` ships with DBR 14.3, so no maven coordinate).

Jira progress comment posted (id 5135422).

### Notes / open items

- **Unvalidated:** couldn't run `databricks bundle validate` locally (SAML SSO blocks the CLI). First `deploy_to_dev` run is the real test of `notebook_path` local-source resolution and the notebook's sibling `from utilities...` imports (DAB syncs the whole repo to `${root_path}/files/`; job notebook_task puts the notebook's dir on `sys.path`, same as a Repo run).
- **Remaining DoD (needs Databricks access):** run `deploy_to_dev`; verify dev job runs as the SP; cut a GitHub release to fire `on_release` for prod; verify prod; decommission the old hand-built personal-user job.
- **Gotcha:** pushing to this repo required a full GCM credential erase + fresh browser SSO auth (`git credential-manager erase` for github.com), not just reconnect. Posting Jira comments required a full Atlassian MCP disconnect → authenticate → approve cycle to grant write scope; reconnect alone kept returning 403 "app is not installed".
