# LND-7358: Gathered batches not loaded to DS9

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-7358
**Status:** Ready for Dev

The following batches did not make it to DS9:

They are located here: \\smb.dc2isilon.na.drillinginfo.com\lease_data_entry\data_sources\gatherer_archive\

Exist in both cstitle (and for the most part in div1 too):

- WLS#OHIO#PORTAGE#2025-06-27#2025-07-24#LEASES#2#DONE
- WLS#OHIO#MEDINA#2025-07-04#2025-07-31#LEASES#3#DONE
- WLS#OHIO#MEDINA#2022-10-07#2022-11-03#LEASES#1#DONE
- WLS#OHIO#WASHINGTON#2025-05-16#2025-06-19#LEASES#1#DONE
- WLS#OHIO#WASHINGTON#2025-08-15#2025-09-18#LEASES#2#DONE
- WLS#OHIO#CUYAHOGA#2025-07-18#2025-08-14#LEASES#3#DONE (2 should be online, the other was filtered out)
- WLS#OHIO#CUYAHOGA#2025-08-15#2025-09-18#LEASES#1#DONE
- WLS#OHIO#GEAUGA#2025-09-26#2025-10-30#LEASES#1#DONE
- WLS#OHIO#SUMMIT#2025-10-31#2025-11-27#LEASES#1#DONE
- WLS#OHIO#WAYNE#2025-11-07#2025-12-04#LEASES#1#DONE
- megan.nye#Kansas#Miami#2025-07-16#2025-09-09#leases#1#READY

Only 1 record from the batch is in DS9:

- WLS#OHIO#WASHINGTON#2025-10-17#2025-11-20#LEASES#11#DONE (only 1 in DS9)
  - 111 page file in batch
  - seems okay - maybe gatherer put wrong number
- megan.nye#Kansas#Gove#2025-10-22#2025-11-24#leases#12#READY (only 1 in DS9)
  - Missing leases spreadsheet: LND-7358 Missing Leases in DS9 (SharePoint, lindsey_chambers)
  - 12 records in batch in gatherer folder
  - all look good in cstitle in status 4
  - no leaseid in tblexportlog
  - in div1 I can find these
  - in diweb I can find them by recordnumber
- megan.nye#Kansas#Gove#2025-08-27#2025-10-21#leases#35#READY (only 1 in DS9)

Not processed at all:

- WLS#PENNSYLVANIA#ARMSTRONG#2025-11-14#2025-12-11#ASSIGNMENTS#2#DONE (not pulled by process, no extra quotes found, maybe pdfs too big?)
- WLS#PENNSYLVANIA#ARMSTRONG#2025-11-14#2025-12-11#LEASES#140#DONE (not pulled by process, corrected 1 extra quote and still not pulled, maybe pdfs too big?)
- CatherineClarke#Texas#Willacy#2025-04-01#2025-04-30#Leases#1#DONE (not pulled by process)
- CatherineClarke#Texas#Willacy#2023-08-01#2023-08-31#Assignments#1#DONE (not pulled by process)

### Comments

2026-01-28, Alejandra Pierce: The two Armstrong batches (ASSIGNMENTS#2 files renamed; LEASES#140 corrected 1 extra quote) were then pulled by the process and are now in cstitle. She will re-check after keying and comment if they don't reach DS9.

2026-05-05, Alejandra Pierce: Additional batches not in DS9:

- WLS#OHIO#LICKING#2026-01-30#2026-02-26#LEASES#2#DONE
- CatherineClarke#Texas#Willacy#2025-12-01#2025-12-31#Leases#1#DONE
- WLS#MICHIGAN#MISSAUKEE#2026-01-02#2026-02-05#LEASES#1#DONE
- megan.nye#Kansas#Gove#2026-01-15#2026-02-23#leases#4#READY (2 records not in DS9: 20260078, 20260050)
- WLS#OHIO#PORTAGE#2026-02-27#2026-03-26#LEASES#2#DONE (1 record not in DS9: 202603562)

2026-05-19, Alejandra Pierce: One more, dragged into the processed folder but not showing in cstitle:

- baguio#weld#colorado#2026-03-30#2026-04-24#leases#185#DONE

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
