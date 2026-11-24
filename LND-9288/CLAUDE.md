# LND-9288: Fix Stale Assignments on StatusID 90 Migrated Leases

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9288
**Status:** Ready for Dev

**Summary**

LND-6732 set StatusID 90 on migrated leases and left a tblExportLog row on each. The cstitle provider in land-lease-producer requires StatusID IN (4,10,16), and the Div1 provider skips every lease that has a tblExportLog row. Neither provider republishes these leases, so later assignment changes never reach Kafka or DS9 and the old DS9 rows persist. 3,637,101 leases are StatusID 90, and 62,349 of them have an assignment change since the migration. Done means the affected leases are set to a publishable status in CountyScansTitle (the preferred source, because its values are keyed rather than taken from digital DIV1), republished by land-lease-producer, and correct in DS9.

**Steps to Reproduce**

1. Take Armstrong PA assignment 202511310 (StatusID 4, exported 2026-02-06). Its leases are 2510566 (record 0bbae337-700b-49bd-b858-b2d16805cbbd) and 2469097 (record e6b6a304-6669-44e8-816e-8a66d53216c2).
2. Confirm both lease records are StatusID 90 and have a tblExportLog row (zipName 'LND-6732(2)', 2025-09-22).
3. Check DS9 pres.lease_assignment_detail and the pres.legal_lease assignment summary for both leases.

**Expected Behavior**

The new assignment reaches DS9. legal_lease shows CNX Gas Company 100% (2025-11-14, 5909/283) for 2510566 and 'Complex - See Detail' for 2469097, and lease_assignment_detail has 6 rows across the two leases.

**Actual Behavior**

DS9 has no rows for assignment 202511310 and keeps the old pre-migration assignee. Assignments.legal_lease_mapping in CSTitle already holds the correct summary (modified 2026-02-06), but the producer never reselects the leases.

**Impact / Severity**

62,349 leases have an assignment change after export that cannot reach DS9. 62,334 are in legal_lease and 15 are not. Comparison of CSTitle against DS9 (2026-11-04): ds9HasNoAssignment 13,442; assigneeDiffers 18,510; partyCountDiffers 29,699 (not sampled); current 683; notInLegalLease 15. Largest counties: Tarrant TX 11,256, De Soto LA 4,320, Belmont OH 2,503, Dewey OK 2,498. Edits, polygon changes and grantee alias changes on the other ~3.6M leases are also not propagated and cannot be sized.

**Environment**

Prod. land-lease-producer (cstitle and Div1 providers), CSTitle tblrecord and tblExportLog, DS9 via the Glue job. Analysis and queries (query_3, query_4, query_32 to query_37) are in https://github.com/donald-massey/jira-repos/tree/main/LND-7358.

**Definition of Done**

- [ ] Manager confirms the approach: flip StatusID to a publishable status (4, 10 or 16) in CountyScansTitle, versus a land-lease-producer change so the Div1 provider owns StatusID 90 leases
- [ ] Scope of the flip is decided: all 62,349 stale leases or a subset
- [ ] Current DS9 legal_lease rows for 2510566 and 2469097 are saved before the flip (mapping_ids 3960761 and 3870640/3870641; record numbers 2006-006322 and 200202868)
- [ ] Effect of the flip is checked: at status 4 the cstitle provider publishes CSTitle land descriptions, record number and image links instead of the earlier Div1 data. Other consumers of status 4 records (ch-lease-exporter, COLE, courthouse-land-data-loader) are checked
- [ ] Status change is run manually, not from a script
- [ ] LastProcessedDateLandLeaseProducer in tblDataLoadersPerCounty is set back for the affected counties so land-lease-producer republishes them (per county only; do not reset it globally)
- [ ] Verified in Dev first: both Armstrong leases are selected by the cstitle provider and DS9 shows the expected assignment rows
- [ ] Kafka and Glue capacity is checked before the Prod run (first run publishes the backlog in 500-lease batches), and consul-kv and the MyGlue entry are verified before any Dev or Prod push
- [ ] Prod republish verified in DS9 by re-running the CSTitle versus DS9 comparison (query_36 and query_37)
- [ ] The 15 leases not in legal_lease are explained, and partyCountDiffers (29,699) is sampled to find out whether it is real staleness

**Risk if Deferred**

Another 300 to 9,000 migrated leases a month get assignment changes that never reach DS9 (2026-09 alone added 26,457), and DS9 keeps showing outdated assignees.

Found in LND-7358.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
