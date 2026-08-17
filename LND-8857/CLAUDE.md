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

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
