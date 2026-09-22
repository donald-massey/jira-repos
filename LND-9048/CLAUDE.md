# LND-9048: Validate DAGs in New Airflow Dev Instance

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9048
**Status:** In Progress

**Summary**

A new Airflow Dev instance has been provisioned and all existing DAGs need to be validated before it becomes the primary Dev environment. Two developers will split the validation work, confirming each DAG matches Prod in code, schedule, variables, and runtime behavior. The old Dev Airflow was not configured accurately, so Prod is the authoritative baseline for comparison.

- Prod Airflow: https://airflow.drillinginfo.com/admin/
- New Dev Airflow: https://ea-land-airflow-dev.int.enverus.com/

**Given**

A new Airflow Dev instance is available. DAG configurations — code, schedules, and variables — must match Prod Airflow before teams rely on it for development and testing. The old Dev Airflow was not configured accurately and is not a valid baseline.

**Expect**

All DAGs have been verified against Prod Airflow. Any discrepancies are documented and resolved before the new instance is put into use.

**Definition of Done**

- [ ] DAG code in the new Dev instance matches Prod Airflow (side-by-side comparison or diff)
- [ ] DAG schedule matches the Prod Airflow schedule for each DAG
- [ ] All DAGs from Prod Airflow exist in the new Dev instance
- [ ] DAG variables and connections in the new Dev instance match Prod Airflow
- [ ] Each DAG has run at least once successfully in the new Dev instance

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
