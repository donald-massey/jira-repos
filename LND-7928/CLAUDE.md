# LND-7928: Update Auto Aliasing (Grantee Aliasing code base) to use CountyScansTitle as source for Grantees

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-7928
**Status:** Ready for Dev

Given: LND-7491 (https://enverus.atlassian.net/browse/LND-7491) updates the data entry workflow/application to use CountyScans Title as a source for grantees to be aliased, we need to make sure this code base (which automates the manual workflow) is in sync with that change.

The exact logic as to how to query that is in the solution for LND-7491. I haven't personally validated that the logic is correct but I'm imagining something like:

1. Select all leases from CSTitle using tblExportlog and the recordisleasing = 1 flag (or some combination of these).
2. Add a step to copy all of these grantees (that may not appear in the div1.tblLeaseGrantee) into the gis_aliasing.tblLeaseGrantee (or a separate table that is then unioned up in a subsequent step).
3. Then the normal aliasing workflow should work as the land lease producer reads in all of the aliases from the gis_aliasing tables.

I thought this would solve LND-7701 (https://enverus.atlassian.net/browse/LND-7701) because when I looked in Div1.tblLeaseGrantee, I didn't see "Diamondback", which felt like a hole in the Grantee aliasing workflow. Leases from CSTitle weren't getting their aliases queued up for aliasing. Nathan never saw that one in his GIS_Aliasing.tblLeaseGrantee either (which is a straight copy from div1). Garth worked on LND-7491 which may have included logic to start copying these in at the start up of the app, so you may see it in there now.

Ideally, this auto aliasing will deploy before we tell GIS team to start manually aliasing the new ones that get queued up.

Expect: update code base to source Grantees that don't yet have an alias here:

- https://git.drillinginfo.com/Land/auto-aliasing
- https://enverus.atlassian.net/wiki/spaces/DAQ/pages/9909404122/Landtrac+Lease+Grantee+Aliasing
- v03henpdb01.na.drillinginfo.com.GIS_aliasing

### Comments

- **Lindsey Chambers (2026-08-04):** We need auto aliasing to run in production using CSTitle as a source before we ask Nathan to go do Grantee Aliasing or he'll have a lot of manual work that could have been automated. @Chad Hutcherson if your team has bandwidth it would allow us to release the app changes Garth and Ky had been working on.
- **Chad Hutcherson (2026-08-04):** @Lindsey Chambers We can talk about this one in planning on Thursday. I'm not sure what all it will take but I think the team can figure it out.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
