# LND-8911: Investigate tblDaapUnit Update Stoppage in Div1 Since 2026-07-14

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8911
**Status:** Backlog

**Summary**
tblDaapUnit in Div1 stopped receiving new records as of 2026-07-14. Since DaapUnit IDs are the key that feeds the daapID-update GIS queuing script and the landtrac_unit_to_kafka Airflow job, this stoppage will silently create a growing coverage gap for any wells created after 7/14 — those wells will never be queued for GIS plotting and will never flow through the unit manufacturing pipeline.

**Steps to Reproduce**

1. Query tblDaapUnit in Div1 for records created after 2026-07-14
2. Confirm no new rows exist despite new wells being added to tblWell

**Expected Behavior**
New wells added to Div1 should trigger creation of a corresponding DaapUnit ID in tblDaapUnit.

**Actual Behavior**
tblDaapUnit has not received new records since 2026-07-14.

**Impact / Severity**
Wells created after 7/14 have no DaapUnit ID → not queued for GIS plotting → no polygon drawn → never loaded to Kafka → missing from Prism, DI Web, and DirectAccess. Gap is growing daily and silent.

**Environment:** Div1 (prod), tblDaapUnit; also affects daapID-update GIS layer and landtrac_unit_to_kafka Airflow job (5am CT daily).

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
