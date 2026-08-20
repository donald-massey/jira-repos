# LND-8857 — Dev Test & Prod Promotion Runbook

Deploy and verify the `landtracs_geom_update` Databricks Asset Bundle, first in **dev**, then promote to **prod**.

- **Repo:** `enverus-ea/land.landtracs-geom-update-spark` (default branch `master`)
- **Feature branch / PR:** `LND-8857` / PR #7
- **Bundle:** `landtracs_geom_update` (`databricks.yml`)
- **Dev workspace:** https://enverus-ea-ue1-dev.cloud.databricks.com
- **Prod workspace:** https://enverus-ea-ue1-prod.cloud.databricks.com
- **Runs as:** `sp-ea-land-power-user` (SP creds pulled from Vault by both workflows)

---

## 0. Prerequisites (one-time)

- [ ] PR #7 reviewed and approved.
- [ ] **Merge PR #7 → `master`.** This is required *before* dev can be triggered: `deploy_to_dev.yml` uses `on: workflow_dispatch`, and GitHub only registers the **Run workflow** button once the workflow file exists on the **default branch** (`master`). Until merged, the button won't appear and `gh workflow run` fails the same way.
- [ ] Confirm you have access to both Databricks workspaces (dev + prod) to observe runs.

> The `Dev` / `Prod` branches in this repo are **legacy** from the old manual setup. This DAB flow does **not** use them — promotion is workspace-based (dev workspace vs prod workspace), selected by `DATABRICKS_BUNDLE_ENV` inside the workflows. Do not promote through those branches.

---

## Part A — Test in Dev

### A1. Trigger the dev deploy

1. GitHub → repo → **Actions** tab.
2. Select **"Deploy Feature Branch to DEV"** (`deploy_to_dev.yml`).
3. **Run workflow** → branch **`master`** (post-merge the code is identical to `LND-8857`).
4. Watch the two jobs:
   - `validate` → `databricks bundle validate` (dev env).
   - `deploy` → `databricks bundle deploy --force --var="version=<branch>-<sha>"` to the dev workspace.
5. Both must be green. A failure here is almost always bundle YAML (variable reference / schema) or the Vault secret lookup at `enverus-ea/databricks/sp-ea-land-power-user`.

### A2. Confirm the deploy landed

1. Dev workspace → **Workflows**.
2. Find the job — dev is `mode: development`, so the name is **prefixed** (e.g. `[dev sp-ea-land-power-user] landtracs-geom-update`), deployed under `~/.bundle/dev/landtracs_geom_update`.
3. Open the job and confirm:
   - [ ] Task is a `notebook_task` pointing at the synced notebook under the bundle `files/` path.
   - [ ] Cluster: `SINGLE_USER`, `c6gd.2xlarge` ×4, policy `job-cluster-policy-aws-s3-adl-v1`, Spark `14.3.x-scala2.12`.
   - [ ] Libraries: `elm-utils`, `folium==0.14.0`, `geopandas==1.0.1`, `sqlalchemy==1.4.45`, `pyodbc==4.0.39`.
   - [ ] **Init script** present: `${workspace.file_path}/scripts/install_msodbcsql.sh` — installs `msodbcsql18` on driver + all workers (pyodbc runs on executors, so a notebook cell can't cover it).
   - [ ] **Schedule shows PAUSED** — Airflow stays the primary trigger; you don't want the cron firing on its own.

### A3. Run it manually (`Environment=DEV`)

1. **Run now** on the job.
2. `Environment` resolves from `base_parameters: { Environment: "${var.env}" }` → **`dev`**. Confirm the notebook's `dbutils.widgets.get("Environment")` picks up DEV.
3. **Cluster startup — init script.** `msodbcsql18` installs on driver + all workers via `scripts/install_msodbcsql.sh` *before* the notebook runs. If it fails, the run never starts and the cluster event log / init-script logs show the error. Two known failure modes:
   - **UC allowlist:** on a Unity Catalog SINGLE_USER cluster the init-script path may need to be on the metastore allowlist — a `... is not on the allowlist` event means add `${workspace.file_path}/scripts/install_msodbcsql.sh` to the allowlist (Catalog → metastore init-script allowlist) and re-run.
   - **Package egress:** if `packages.microsoft.com` is blocked or transiently down, the `apt-get`/`dpkg` step fails and node bootstrap aborts (`set -e`).
4. Let the run complete.

### A4. Verify (Dev)

- [ ] **Identity:** run executed as `sp-ea-land-power-user` (check run detail / cluster event log), **not** a personal account.
- [ ] **Target DB:** connected to the **dev** Hendrix `V03HENDDB01` (not prod `V03HENPDB01`).
- [ ] **JDBC read** from DIV1 succeeded (`spark.read.jdbc`, driver ships with DBR 14.3 — no install needed).
- [ ] **Write** populated `sde.DI_LANDTRAC_POLYGONS` on the dev target.
- [ ] QA comparison table populated; invalid/empty geometry deletes ran without error.

> ⚠️ A full run **mutates** `DI_LANDTRAC_POLYGONS` (bulk WKT insert + `DELETE` of invalid/empty geometries). If dev is not disposable, point the first smoke run at a scratch table before running against the real dev table.

### A5. Geometry regression check (post geopandas 1.0.1 upgrade)

**Why:** the DAB run installs `geopandas==1.0.1`, which pulls a newer **shapely 2.x / GEOS** than the old `0.13.0` cluster. Reprojection (`to_crs` NAD27→NAD83→WGS84), `make_valid`, interior-polygon `difference()`, and WKT rounding all route through GEOS, so output geometry could drift subtly even though the code is unchanged. This step proves it didn't — **gate the cutover (A6) on it.**

**Baseline:** the backup of `sde.DI_LANDTRAC_POLYGONS` taken **before** this run (i.e. the last geopandas-0.13 output). Substitute its name for `{BACKUP_TABLE}` below.

After the A3 run completes and A4 confirms the write, run this **read-only** comparison on the dev Hendrix `V03HENDDB01`:

```sql
DECLARE @tol float = 1e-9;   -- sq-degree area tolerance; below this = floating-point noise, not real drift

-- 1. Row counts must match
SELECT
    (SELECT COUNT(*) FROM [gis_exports].[sde].[{BACKUP_TABLE}])       AS backup_rows,
    (SELECT COUNT(*) FROM [gis_exports].[sde].[DI_LANDTRAC_POLYGONS]) AS new_rows;

-- 2. leaseIds present on only one side (added or dropped)
SELECT 'only_in_backup' AS side, b.leaseId
FROM [gis_exports].[sde].[{BACKUP_TABLE}] b
LEFT JOIN [gis_exports].[sde].[DI_LANDTRAC_POLYGONS] n ON n.leaseId = b.leaseId
WHERE n.leaseId IS NULL
UNION ALL
SELECT 'only_in_new', n.leaseId
FROM [gis_exports].[sde].[DI_LANDTRAC_POLYGONS] n
LEFT JOIN [gis_exports].[sde].[{BACKUP_TABLE}] b ON b.leaseId = n.leaseId
WHERE b.leaseId IS NULL;

-- 3. Matching leaseIds whose geometry actually changed beyond tolerance
SELECT
    n.leaseId,
    b.Shape.STEquals(n.Shape)                 AS topo_equal,     -- 1 = topologically equal
    b.Shape.STArea()                          AS backup_area,
    n.Shape.STArea()                          AS new_area,
    ABS(b.Shape.STArea() - n.Shape.STArea())  AS area_delta,
    b.Shape.STSymDifference(n.Shape).STArea() AS symdiff_area
FROM [gis_exports].[sde].[{BACKUP_TABLE}] b
JOIN [gis_exports].[sde].[DI_LANDTRAC_POLYGONS] n ON n.leaseId = b.leaseId
WHERE b.Shape.STEquals(n.Shape) = 0
  AND b.Shape.STSymDifference(n.Shape).STArea() > @tol
ORDER BY symdiff_area DESC;
```

**Pass criteria:**
- [ ] Query 1: `backup_rows` == `new_rows`.
- [ ] Query 2: returns **zero rows** (no leaseId added or dropped).
- [ ] Query 3: returns **zero rows** (no geometry drift beyond `@tol`).

If query 3 returns rows, inspect the top `symdiff_area` cases visually (WKT / on a map) before deciding — a handful of sub-tolerance vertex shifts from a GEOS version bump may be acceptable, but changed row counts or large `symdiff_area` are a real regression. **Do not proceed to A6 until this passes or the diffs are explicitly signed off.**

### A6. Repoint the dev Airflow variable (cutover)

The `land-lease-producer` DAG triggers this notebook as **stage 1** via a Databricks `job_id` stored in an Airflow Variable. The DAB deploy created a **new** job with a **new** id, so the variable must be repointed or the DAG keeps firing the **old** hand-built job.

1. Get the new dev job id — either:
   - Workflows UI → open the job → **Job details** (the numeric **Job ID**, also in the job URL `#job/<id>`), or
   - CLI: `databricks bundle summary -t dev` (lists deployed resources + ids).
2. Dev Airflow → **Admin → Variables** → edit `land_lease_producer` (id **6619**): https://airflow.dev.drillinginfo.com/admin/variable/edit/?id=6619
3. Update **`databricks.job_id`** to the new dev job id. Leave everything else (`connection_id: land.databricks`, glue/poll/schedule) unchanged:
   ```json
   "databricks": {
       "job_id": "<NEW_DEV_JOB_ID>",
       "connection_id": "land.databricks"
   }
   ```
4. **Record the old id** (`178246000480874`) before overwriting — that's the rollback value.
5. Trigger the DAG (or wait for the `0 23 * * *` schedule) and confirm stage 1 launches the **new** DAB job.

---

## Part B — Promote to Prod

Prod deploys on **GitHub release publish** (`on_release.yml`) — not on a branch push. `master` must already contain the merged PR (Part A, step 0).

### B1. Cut the release

1. GitHub → repo → **Releases** → **Draft a new release**.
2. **Tag:** semver, e.g. `v1.0.0` (the workflow extracts it: `refs/tags/v1.0.0` → `--var="version=v1.0.0"`).
3. **Target:** `master`.
4. **Publish release.**

### B2. Watch `on_release.yml`

1. Actions → **"On Release - Update Production Job"**.
2. Job order (gated):
   - `validate` → `databricks bundle validate -t prod` (prod env). **Newly added gate — a malformed bundle fails here and deploy never starts.**
   - `deploy` (`needs: [validate]`) → `databricks bundle deploy -t prod --var="version=<tag>"`.
3. Both must be green.

### B3. Confirm the prod deploy + run

1. Prod workspace → **Workflows** → `landtracs-geom-update` (prod is `mode: production` — **no** dev prefix), under `/Shared/.bundle/prod/landtracs_geom_update/files`.
2. Confirm:
   - [ ] `run_as` = `sp-ea-land-power-user` (set explicitly in the prod target).
   - [ ] Schedule **PAUSED**.
   - [ ] Cluster / libraries / **init script** match Part A2 (the `install_msodbcsql.sh` init script is wired for prod too).
3. **Run now.** `Environment` → **`prod`**.
4. Watch cluster startup — the `install_msodbcsql.sh` init script runs on all nodes before the notebook. If prod enforces the UC init-script allowlist, the path needs allowlisting in the **prod** metastore (see A3 step 3).

### B4. Verify (Prod)

- [ ] Run executed as `sp-ea-land-power-user`.
- [ ] Connected to **prod** Hendrix `V03HENPDB01`.
- [ ] `sde.DI_LANDTRAC_POLYGONS` written on the prod target; QA table populated.
- [ ] Row counts / geometry sanity comparable to the historical hand-built job's output.

### B5. Repoint the prod Airflow variable (cutover)

Same as A6, but against **prod** Airflow and the **prod** job id.

1. Get the new **prod** job id (prod Workflows UI or `databricks bundle summary -t prod`).
2. Prod Airflow → **Admin → Variables** → edit the prod `land_lease_producer` variable (prod Airflow has its own copy — **not** dev id 6619; find it via search).
3. Update **`databricks.job_id`** to the new prod job id; leave `connection_id` and the rest unchanged.
4. **Record the old prod id** before overwriting (rollback value).
5. Trigger the DAG and confirm stage 1 launches the new DAB job in the prod workspace.

> The prod variable also differs from dev in `glue_job_name` (e.g. `land-*-kafka-to-adl`) and notify/email targets — **only** change `databricks.job_id`.

---

## Part C — Decommission the old job

The cutover itself is the Airflow variable repoint (A6 / B5). Only after that is verified:

- [ ] Airflow DAG (`land-lease-producer`, stage 1) confirmed triggering the **new DAB** `job_id` in both envs (A6 step 5, B5 step 5).
- [ ] Old hand-built, personal-user Databricks job **paused** (not deleted) for one full Airflow cycle as a fallback — do **not** delete while it's still the rollback target.
- [ ] After a clean cycle, the original job owner **deletes** the old job.

---

## Rollback

- **Bad run / wrong new job:** revert the Airflow variable `databricks.job_id` to the recorded old id (dev `178246000480874`; prod: the id you recorded in B5). The DAG immediately goes back to the old job — this is the fastest rollback, and why the old job stays **paused, not deleted**, through the first cycle.
- **Bad prod deploy:** re-publish a release pointing at the previous good tag → `on_release` re-deploys that version. Or `databricks bundle deploy -t prod --var="version=<prev>"` from a clean checkout of the prior tag.
- **Bundle validate fails on release:** nothing deployed (that's the point of the B2 gate) — fix YAML on `master`, cut a new release.

---

## Quick reference

| | Dev | Prod |
|---|---|---|
| Trigger | Actions → Run workflow (`deploy_to_dev.yml`) | Publish GitHub Release (`on_release.yml`) |
| Workspace | `enverus-ea-ue1-dev` | `enverus-ea-ue1-prod` |
| Bundle mode | `development` (name prefixed) | `production` |
| `Environment` param | `dev` → `V03HENDDB01` | `prod` → `V03HENPDB01` |
| Identity | `sp-ea-land-power-user` (Vault creds) | `sp-ea-land-power-user` (`run_as`) |
| Validate gate | yes (`validate` job) | yes (`validate` job) |
| Schedule (job) | PAUSED | PAUSED |
| Airflow cutover | var `land_lease_producer` id 6619 → new `databricks.job_id` | prod `land_lease_producer` var → new `databricks.job_id` |
| Old job id (rollback) | `178246000480874` | record before overwrite |
