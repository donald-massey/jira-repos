# LND-9157: Fix Zavala Book Types Batch Insert Error

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9157
**Status:** Ready for Dev

**Summary**
cs-digital-mfg is failing on a Zavala digital clerk batch because it tries to insert too many book types. The failure has been recurring for over a week. Done means the book types are fixed using the same procedure as the instrument types fix, the Zavala batch processes, and we know why values from the clerk CSV are truncated in the error message.

**Given**

- cs-digital-mfg reports a batch trying to insert too many book types.
- The fix is essentially the same as the instrument types fix: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/34890384862/Insert+New+Instrument+Types+Into+CS_Digital
- The error message also shows names from the Zavala batch cut off (digital clerk handler, September).
- The error has been happening for over a week.
- Grafana logs: https://enverus.grafana.net/ (Loki, `{environment="prod", service="cs-digital-mfg"} | json | level=~"ERROR"`, last 7d)

**Expect**

- Book types error resolved and the Zavala batch processes through cs-digital-mfg.
- Root cause identified for why some values in the clerk CSV are truncated in the error message.
- A Confluence page documenting the book types fix, modeled on the instrument types page. Lindsey started the page so it should be there for updates: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38701957121/Insert+New+Book+Types+Into+CS_Digital

**Reference / Evidence**

- Package: `\\smb.dc2isilon.na.drillinginfo.com\lease_data_entry\data_sources\digital_clerk\ZAVALA_TX\_PROCESSED\2026_9_106862\Zavala_08-03-2026_to_08-31-2026`
- Truncation example: the index has `PROPERTYMIDLAND` and the error message shows `PROPERTMI`.

**Definition of Done**

- [ ] Pull the new book types from the cs-digital-mfg error for the Zavala batch
- [ ] Confirm they are valid values; check the book type column mapping in the county manifest if they look like junk
- [ ] Insert them into the book types lookup table in CS_Digital [TBD: table name], in the needed environments
- [ ] Reprocess the Zavala batch successfully
- [ ] Compare the raw book type values in the package CSV against the error message and find where PROPERTYMIDLAND becomes PROPERTMI; file a follow-up Bug if the handler is corrupting data
- [ ] Create a new Confluence page, "Insert New Book Types Into CS_Digital", in the DAQ space, modeled on the instrument types page, and link it from there

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
