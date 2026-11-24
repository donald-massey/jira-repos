# LND-9284: Add Willacy County to Gathered Batch Handler Config

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9284
**Status:** In Progress

**Summary**
Willacy County TX is not configured in gathered-batch-handler `county_config.json`, so `generate_manifest` never scans its Catherine Clarke batch folder and three Willacy batches were never pulled into cstitle. Done means a `WILLACY_TX` block is deployed, the Willacy batches load, and the leases reach DS9.

**Given**
Found while investigating LND-7358. `county_config.json` has Catherine Clarke entries for Starr and King (path pattern `Catherine Clarke\Processed\Texas\<County> County, TX`) and no Willacy entry. No commit in git history ever added one, and `generate_manifest` only scans folders listed in the config. The producer has no land-description gate, and these batches never reached it, so land descriptions and filtering are ruled out as the cause.

Batches never picked up (folder `\\smb.dc2isilon.na.drillinginfo.com\leases\Gatherers\Catherine Clarke\Processed\Texas\Willacy County, TX`):

- CatherineClarke#Texas#Willacy#2025-04-01#2025-04-30#Leases#1#DONE
- CatherineClarke#Texas#Willacy#2023-08-01#2023-08-31#Assignments#1#DONE
- CatherineClarke#Texas#Willacy#2025-12-01#2025-12-31#Leases#1#DONE (not in DS9, added 2026-05-05)

**Expect**
Willacy batch folders are scanned by gathered-batch-handler, loaded into cstitle, and the lease records reach DS9 `legal_lease`.

Verified 2026-11-04 (query_7 in the LND-7358 workspace): Willacy is CSTitle `county_id` 245 and Div1 CountyID 243. The query returned no Willacy `tblrecord` rows, no Div1 leases and no `Tracker.MasterTracker` rows, so nothing from these batches was loaded anywhere.

Out of scope: Kenedy County TX is also missing from `county_config.json` and its folder holds an unpicked zip from 2026-06-08. It needs its own decision.

**Definition of Done**

- [x] Willacy CSTitle `county_id` confirmed (245) and no existing Willacy `tblrecord` rows
- [ ] `WILLACY_TX` block added to gathered-batch-handler `county_config.json` (copy of `STARR_TX` with `county_id` 245 and `county_name` WILLACY)
- [ ] Config change deployed (consul-kv checked)
- [ ] The three Willacy batches are pulled into cstitle
- [ ] Willacy lease records verified in DS9 `legal_lease`; the Assignments batch confirmed in the assignment tables

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
