# Missing Legal Lease Investigation — Template

Go-forward method for "recent legal leases not published" cards (LND-8424, LND-8425,
and future ones). Instantiates the published runbook so every card is diagnosed the
same way.

**Runbook (canonical):** https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284/Missing+Legal+Leases+Investigation+Runbook+LND-8426
**Origin ticket:** https://enverus.atlassian.net/browse/LND-8426

## How to use

1. Copy this folder to the ticket workspace: `cp -r _lease-investigation-template/* LND-XXXX/`
   (keep `query_1..query_4`; delete this line and fill in the CLAUDE.md placeholders).
2. Replace every `{PLACEHOLDER}` token in the SQL/PS1 files with the record's values.
3. Run the queries in order — **query_1 (Level 1) first**. Do not skip to Level 2.
4. Record findings under `## Completed` in the ticket CLAUDE.md as you go.

## Placeholders

| Token | Meaning | Example |
| --- | --- | --- |
| `{TICKET}` | Jira key | LND-8424 |
| `{RECORDIDS}` | CSTitle recordID(s), comma-quoted (IN lists) | `'90c3e6e1-...','c5d14542-...'` |
| `{RECORDID_ROWS}` | CSTitle recordID(s) as @records VALUES rows | `('90c3e6e1-...'),('c5d14542-...')` |
| `{LEASEIDS}` | DIV1 LeaseID(s) | `5067911` |
| `{ZIPNAME}` | DIL zip from tblexportLog | `CH_02.14.2024.08.41_leases` |
| `{YYYY-WW}` | ISO week of the zip exportDate | `2024-07` |
| `{STATE}` | state abbreviation | `CA` |
| `{COUNTY}` | county name (upper) | `MERCED` |
| `{LINK}` | CSTitle→DIV1 linked server | `LinktoDiv1Repl` |
| `{CSDIGITAL}` | CS_Digital ref from CSTitle session (default: linked server) | `LINKTOPETL.CS_Digital` |

## The method (two levels + COLE)

```
CSTitle tblRecord -> ch-lease-exporter (DIL zip) -> IIF Lease Importer -> Div1_Daily.tblLegalLease
                                                                       -> tblexportLog (leaseID match)
                                                                       -> land-lease-producer -> Kafka -> land-aws-glue -> ES legal_lease
```

- **query_1 — Level 1: record standing + IIF match.** Start here, in order:
  - `doc_image_paths.sql` (Level 1a) — how the record stands in countyScansTitle (recordNumber,
    statusID, instrumentType, fileDate) and where its image lives (on-prem UNC + S3). **Open the
    PDF and read the legal** — that alone often explains the miss (no legal / map-only doc), and
    the image `_ModifiedBy`/`_ModifiedDateTime` flags cs_updates re-staging (stale-COLE signal).
  - `level_1_exportlog.sql` (Level 1b) — did ch-lease-exporter match the record to a DIV1
    `leaseID`? `leaseID NULL` = IIF never made the DIV1 row (the 08:00–22:00 CST business-hours
    timing race, or a per-record import/match failure); permanently excluded until its tblexportLog
    rows are removed (manual, per the runbook — see the read-only preview). Confirm in the IIF log,
    quantify the batch by `zipName`. `leaseID NOT NULL` → Level 2. No row → not yet exported.
- **query_2 — Level 2 (producer → glue).** Glue's `legal_lease` writer drops any record with
  `mapping_id IS NULL`. `mapping_id` = `land_descriptions[].legacy_mapping_id`, sourced from
  **DIV1 `tblleaseAbstractMapping.mappingid`**. Check DIV1 mapping for the LeaseID + CSTitle
  land descriptions for the record. Also confirm presence/version in the ES `legal_lease` index.
- **query_3 — COLE.** Splits "reprocess candidate" (queue miss / failed OCR-IIE, or image
  overwritten after COLE ran) from "document-type limitation" (COLE ran clean, document has no
  parseable legal). Only relevant when Level 2 shows the legal description itself is missing.
- **query_4 — scale.** Drop-rate by state/county from the candidate universe — is this a
  one-off or a county/state pattern?

## CSTitle-sourced counties (CA and other migrated counties)

Even when a county publishes through `cstitle_lease_data_provider` (not DIV1), the
`legacy_mapping_id` is **still inherited from DIV1**:
`cstitle_lease_data_provider._enrich_land_descriptions_by_div1_legacy_fields()` matches the
CSTitle `tblLandDescription` rows against DIV1 land descriptions for the same LeaseID and copies
`legacy_mapping_id` across. If DIV1 has no abstract mapping for that lease, no `mapping_id` is
assigned and glue drops the record. So the Level 2 mapping gate is DIV1-side regardless of source
system. The LeaseID from Level 1 (`tblexportLog.leaseID`) is the join key into DIV1 — another
reason Level 1 comes first.

**Mapping path by state:** base path (`StateID NOT IN (91,102,93)` — CA and most states) matches
DIV1 land descriptions on section/township/range/block. Parcel path (OH=91, WV=102, PA=93) matches
on parcel number via CSTitle `TblAddsFields`. Use the base-path block in `query_2` unless the
county is OH/WV/PA.
