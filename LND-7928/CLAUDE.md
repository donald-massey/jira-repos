# LND-7928: Update Auto Aliasing (Grantee Aliasing code base) to use CountyScansTitle as source for Grantees

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-7928
**Status:** In Progress

Given: LND-7491 (https://enverus.atlassian.net/browse/LND-7491) updates the data entry workflow/application to use CountyScansTitle as a source for grantees to be aliased. We need to make sure this code base (which automates the manual workflow) is in sync with that change.

The exact logic as to how to query that is in the solution for LND-7491. The reporter hasn't personally validated that the logic is correct, but imagines something like:

1. Select all leases from CSTitle using `tblExportlog` and the `recordisleasing = 1` flag (or some combination of these).
2. Add a step to copy all of these grantees (that may not appear in `div1.tblLeaseGrantee`) into `gis_aliasing.tblLeaseGrantee` (or a separate table that is then unioned up in a subsequent step).
3. Then the normal aliasing workflow should work as the land lease producer reads in all of the aliases from the gis_aliasing tables.

Reporter thought this would solve LND-7701 (https://enverus.atlassian.net/browse/LND-7701) because when looking in `Div1.tblLeaseGrantee`, "Diamondback" wasn't present, which felt like a hole in the Grantee aliasing workflow. Leases from CSTitle weren't getting their aliases queued up for aliasing. Nathan never saw that one in his `GIS_Aliasing.tblLeaseGrantee` either (which is a straight copy from div1). Garth worked on LND-7491 which may have included logic to start copying these in at the startup of the app, so it may be visible in there now.

Ideally, this auto aliasing will deploy before we tell the GIS team to start manually aliasing the new ones that get queued up.

Expect: update code base to source Grantees that don't yet have an alias here:

- Repo: https://git.drillinginfo.com/Land/auto-aliasing
- Confluence: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/9909404122/Landtrac+Lease+Grantee+Aliasing
- DB: v03henpdb01.na.drillinginfo.com.GIS_aliasing

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
