# LND-8849: Convert land.landtracs-geom-update-spark to a Databricks Asset Bundle (service-principal run_as + policy-governed job cluster)

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8849
**Status:** Backlog

### Summary

Convert the landtracs polygon-geometry Databricks job from a hand-built, personally-owned setup to a checked-in Databricks Asset Bundle (DAB) that runs as a service principal on a policy-governed cluster, deployed by GitHub Actions — matching the courthouse-land-data-loader pattern.

### Business Requirement

Remove the single-person dependency (job runs as _my_ user on a cluster _I_ built by hand) so this stage of the daily land pipeline is owned by the team, reproducible from source, and survives my absence. No change to the data it produces.

### Context

The landtracs polygon geometry job runs today as job_id `336658368375831`, created by hand in the Databricks UI: it executes as my user on a manually-built cluster. It is stage 1 of the daily land-lease-producer pipeline (triggered from `land_lease_producer.py` via `run-now`). Target: a DAB deployed by GitHub Actions, running as `sp-ea-land-power-user` on an ephemeral job cluster under policy `job-cluster-policy-aws-s3-adl-v1`.

Repo: https://github.com/enverus-ea/land.landtracs-geom-update-spark

Subtasks:
- LND-8851 (SP setup + verify, Dev + Prod)
- LND-8852 (DAG job_id cutover)
- LND-8853 (decommission old job 336658368375831)

### Acceptance Criteria

- Given the DAB is deployed to a workspace, when the landtracs-geom-update job runs, then it executes as `sp-ea-land-power-user` on a cluster created from policy `job-cluster-policy-aws-s3-adl-v1`.
- Given a policy-built job cluster with the ODBC init script, when the job reads DIV1 (JDBC) and reads/writes Hendrix (SQLAlchemy+pyodbc), then both database paths succeed with no manually-installed driver.
- Given a completed dev run, when `DI_LANDTRAC_POLYGONS` and `DI_LANDTRAC_POLYGONS_QA` are compared to the current hand-built job's output, then row counts match and geometry spot-checks are identical.
- Given the new DAB job is verified in prod, when the DAG is repointed (LND-8852) and old job `336658368375831` is decommissioned (LND-8853), then the daily pipeline runs only the new job, with no double-writes.

### Out of Scope

- The `run-now` trigger credential in land-lease-producer (separate repo; only the job_id pointer is touched, per LND-8852).
- Refactoring pyodbc -> Spark JDBC (deliberately avoided — the init script keeps the code untouched).

### Notes / Risks

- **Init script vs. policy** (load-bearing): notebook hits Hendrix via SQLAlchemy+pyodbc in 8 places (`utilities/database.py:32`, `to_sql` at notebook line 323); a policy cluster won't carry `msodbcsql18`/unixODBC. Init script must install them — confirm the policy permits init scripts; if not, fall back to a JDBC refactor.
- **Networking**: cluster needs routes to on-prem SQL Servers (`AUS2-GIS-DDB02`, `V03HENDDB01`/`V03HENPDB01`).
- **Notebook imports**: `from utilities.geo_utils import ...` must resolve as a `notebook_task` (may need a `sys.path` append).
- **JDBC package**: DIV1 read uses `spark.read.jdbc`; `mssql-jdbc` currently comes via `spark.jars.packages` in `storage.py` — prefer declaring it as a maven cluster library.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
