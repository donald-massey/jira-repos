# LND-6796: tblDimlXref shared/duplicate package_id — Investigation & Fix

## What the Card Says

Title: `[CS_Digital].[dbo].[tblDimlXref] contains records with same package_id`
Reporter: Denison (Ales Fexa) | Assignee: Donald Massey | Status: In Progress
https://enverus.atlassian.net/browse/LND-6796

**Givens:**
- 65,148 `package_id`s have multiple `record_id`s.
- Some records sharing a `package_id` (example: `cva8kol48bhg00fiq20g`) are from different counties.
- `package_id` locates the OCR/IIE artifacts for an instrument. If the underlying PDFs for one `package_id` differ, COLE may OCR the wrong PDF, and LLM summarization inherits the error.

**Expect** — investigate instruments sharing a `package_id` and confirm: **(a)** no cases with different PDFs; **(b)** no cases with different instrument county. Then, **if needed, produce a fixed dataset for COLE** to re-compute potentially-affected records.

**From Denison's comment (context):** COLE was already fixed in **LND-6792** to tolerate a `package_id` used for multiple instruments. Div1's fixed dataset uses `tblLeaseIdXref` (no shared package_ids → not affected). This ticket is also the fix for the **land-lease-producer failure**; hardening the producer against duplicate package_ids is an alternative that unblocks increments but doesn't fix the root cause.

## Current structure — one headline, three worked slices

The 65,148 headline ("package_ids with >1 xref row") decomposes into **three disjoint slices**. **Issue 1 (orphans) is the primary issue that stays on this card;** Issue 2 was split into sub-task **LND-8451** (own repo) and Issue 3 into standalone Task **LND-8452** (own repo, "split from" LND-6796). The three are independent and can be done in any order.

| Repo | Slice | Scope | Status |
|------|-------|-------|--------|
| **this repo** (flat root) | **Orphaned recordIDs** (this card) | ~71,075 recordIDs under multi-record package_ids absent from `CS_Digital.dbo.tblRecord` | primary; cleanup ready |
| _(own repo **LND-8451**)_ | **Duplicate xref rows** (one recordID → two package_ids; the producer-crash population) | 4,500 recordIDs (2,830 live + 1,670 orphan) | split out to `github.com/donald-massey/LND-8451`; dedupe ready |
| _(own repo **LND-8452**)_ | **Cross-county / different-document** (one package_id → many recordIDs) | 2,307 package_ids → 4,838 records | split out to `github.com/donald-massey/LND-8452`; needs county + DIML fixes (not blocked on LND-6879) |

The 2,307 (package_id axis) and 4,500 (recordID axis) are different axes; neither is a subset of the 65,148. Full orphan narrative: `LND-6796_ISSUE_AND_FIX.md`. Root cause posted to Jira comment **5005157**.

## Tables (all LOCAL to CS_Digital — no linked server)

| Table | Role |
|-------|------|
| `[CS_Digital].[dbo].[tblDimlXref]` | `package_id` <-> `RecordID` (the problem table, CSTitle path) |
| `[CS_Digital].[dbo].[tblRecord]` | `RecordID` -> `countyId` |
| `[CS_Digital].[dbo].[tblLookupCounties]` / `[tblLookupStates]` | `countyId`/`stateId` -> county/state name |
| `[CS_Digital].[dbo].[tblLeaseIdXref]` | Div1 path (`package_id` -> `lease_id`); no duplicates, not in scope |

Match exact column casing against the schema (global rule).

## Root Cause (confirmed from code; `cs-digital-mfg`)

Xref rows are written by **`cs-digital-mfg`** (`clerk_load.process_county` → `TblDimlXRef.insert/update`). `csdigital-to-cstitle` and `land.courthouse-ocr-legals-extractor` (COLE) only **read** the xref. The loader classifies insert-vs-update by matching `tblRecord` on `(StateID, CountyID, normalized recordNumber, fileDate)`; **`package_id` is not in the match key**, `TblDimlXRef.insert` has no existence check, and there is no unique constraint on `tblDimlXref.recordID`. That single writer produces all three slices:

- **Cross-county (Issue 3):** the same document (same package_id) re-scraped under a different `diml_county_name` misses the county-scoped match → classified NEW → new `newid()` recordID + new xref row with the *same* package_id. Upstream driver = unstable scraper county = **LND-6879**.
- **Duplicate rows (Issue 2):** a later load re-associating an existing record to a new package_id appends a second xref row instead of replacing → one recordID, two package_ids.
- **Orphans (Issue 1):** when a record is later deleted from `tblRecord`, its xref row isn't always removed → an xref row whose recordID no longer exists in `tblRecord`.

Writer files (`C:\Users\donald.massey\PycharmProjects\cs-digital-mfg`): `cs_digital_mfg/mfg/clerk_load.py`, `cs_digital_mfg/db/models.py` (`TblDimlXRef.insert/update`), `sql_templates/new_record_query.sql` + `existing_record_query.sql`.

## Findings by slice

**Issue 1 — orphans (primary).** ~71,075 recordIDs under multi-record package_ids absent from `CS_Digital.dbo.tblRecord`. Cross-DB check (2026-07-02, all three courthouse DBs): **70,921 true orphans** (absent everywhere), **153 in `countyScansTitle`**, **1 in `courthousedirecttitle`**. **Decision 2026-07-09: delete only the 70,921 true orphans; KEEP the 154 sibling-DB records** (their CS_Digital xref rows stay — Section 1 `#keep` excludes them). Purge axis: of 63,947 distinct package_ids under the orphans, only **368 are fully orphaned** (`live_record_count = 0`, DIML purge candidates); 63,579 are still shared with a live record.

**Issue 2 — duplicate xref rows.** 4,500 recordIDs × two package_ids (9,000 rows). Splits **2,830 live** (the only population the producer pulls) + **1,670 orphan**. DIML content check (full prod run 2026-06-30): **same_pdf 4,463 / missing_pdf 25 / different_pdf 12**, 0 errors — **all 2,830 live are same_pdf**, so the scoped dedupe is unconditionally safe; the 37 ambiguous are all orphans. No evidence of producer impact (control table advances every county; 22 clean prod runs 06-09→06-30).

**Issue 3 — correctness.** (b) different county **2,192** package_ids; (a) different document **668**; union **2,307 → 4,838 records**, 100% Oklahoma (confirms LND-6879). COLE recompute needs county corrected first + DIML package→PDF binding fixed (gates below).

## COLE decision gates — RESOLVED from code (`land.courthouse-ocr-legals-extractor`)

- **IIE trusts the supplied `countyName`** (`single_chunk_iie_processor.py`) — no document-based county detection. ⇒ the 2,192 cross-county records need `tblRecord.countyID` corrected **before** recompute.
- **OCR re-pulls the PDF from DIML by `package_id`** (`single_chunk_ocr_processor.py`); `imageLocation` is a fallback only. ⇒ the 668 different-PDF records must be fixed at the **DIML package→PDF binding**, not `imageLocation`.
- OCR/IIE artifacts are keyed by `package_id` (last-writer-wins) — shared package_ids must be split/deduped before recompute (LND-6792 made COLE tolerant, but recompute is not per-record).

## How land-lease-producer uses this

`image_enricher.py` / `iie_enricher.py` call `get_package_ids()` → query `tblDimlXref` by `RecordID` → `pd.merge` back on `record_id`. A recordID with >1 xref row explodes that instrument (Issue 2 crash mode). Key files (`C:\Users\donald.massey\PycharmProjects\land-lease-producer`): `lease_producer/image_enricher.py`, `lease_producer/iie/iie_enricher.py`, `data_providers/cstitle_lease_data_provider/{databases.py, sql_templates/csdigital_get_package_ids.sql}`, `data_providers/base_lease_data_provider.py`.

## Related Issues

- **LND-6792** (Done) — COLE fixed to tolerate a `package_id` shared across recordIDs. Pre-req complete.
- **LND-6879** (Done) — "OKCR - Lease Scraper Loading to Wrong Counties". Upstream root-cause driver of Issue 3, **not a blocker** — the correction can proceed independently. If 6879 back-tags existing OK records, re-measure first since some of the 2,307 may self-resolve.

## Artifacts

All files live at the repo root (previously split across `issue1_orphans/` and `shared/`). `README.md` documents every file; the table below is the working-notes view.

| File | What |
|------|------|
| `LND-6796_ISSUE_AND_FIX.md` | Orphaned-recordID root cause + cleanup narrative + 154-record status (the card's primary write-up) |
| `LND-6796_primary_issue_orphan_cleanup.sql` | Server-scoped queries: Q1/Q2 **review only** the 153/1 kept records on the sibling servers (no delete); Q3 (CS_Digital) — **Section 0** lists surviving live records under the affected package_ids, **Section 1** builds `#orphans` and loads the 154 kept IDs into `#keep` (excluded), **Section 1b backs up the exact deletion set** (`SELECT x.*` = all tblDimlXref columns → `backup/LND-6796_shape1_deleted_xref_backup.csv`), Section 3 deletes the **70,921 true orphans** (dry-run → COMMIT), Section 4 verifies (4a=0, 4b=154 kept) |
| `LND-6796_orphan_tool.py` | `check` (cross-DB orphan verdict) + `export` (per-DB non-orphan CSVs) subcommands; CSV paths anchored to `csv/` next to the script |
| `csv/LND-6796_shape1_orphans.csv` | 71,075 `package_id, orphaned_RecordID, live_record_count` (drives the 368 purge-candidate count) |
| `csv/LND-6796_shape1_orphan_xdb_results.csv` | per-recordID verdict across the three DBs (70,921 / 153 / 1) |
| `csv/LND-6796_shape1_records.csv` | full record detail for the orphaned set (supporting data) |
| `csv/LND-6796_orphans_countyScansTitle.csv` / `csv/LND-6796_orphans_courthousedirecttitle.csv` | `export` output: the 153/1 non-orphans' detail from the sibling DBs |
| `LND-6796.sql` | all original identification queries |
| `diml_fetch_package.py` | `build_client()` — PROD DimlApi, presigned fetch (reused for the optional 368-package DIML existence check) |
| `results.txt` / `review.md` | open-item walk-through + scratch review notes |
| `requirements.txt` / `.env.example` | `diml_api_helper` git tag 1.1.8 + `python-dateutil` + pyodbc + python-dotenv (install needs VPN + SSH to git.drillinginfo.com; interpreter `.venv\Scripts\python.exe`); env template |

**Issue 2 — split out to its own repo `github.com/donald-massey/LND-8451`** (sub-task LND-8451): the duplicate-xref-row dedupe tooling — `README.md`, `identify_duplicate_xref_records.sql` (detect + Shape 2 pivot + live/orphan split), `LND-8451_diml_pdf_check.py` (DIML content check by S3 size+ETag), `LND-8451_dedupe_xref.sql` (scoped dry-run dedupe), and the source CSVs. No longer in this repo.

**Issue 3 — split out to its own repo `github.com/donald-massey/LND-8452`** (Task LND-8452, "split from" LND-6796): the cross-county / different-document correctness work — `README.md`, `identify_correctness_records.sql` (staging + (a) + (b) + COLE union), the (a)/(b) result CSVs, and the 4,838-record COLE dataset. No longer in this repo.

## Database Connections

Three **separate** SQL Server instances — no linked server, no three-part cross-server naming (the cleanup runs each query on its own connection). Credentials in Consul KV / MyGlue; connection env vars mirror land-lease-producer's `docker-compose.yml`.

| DB | Server | Auth |
|----|--------|------|
| CS_Digital | `aus2-ch2-petl01v.na.drillinginfo.com` | Windows |
| countyScansTitle | `AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM` | Windows |
| courthousedirecttitle | `chddb-prod.cg8t5z7xvisu.us-east-1.rds.amazonaws.com` (RDS) | SQL (`CHD_USERNAME=DonaldMassey`) |

## Approach / status

Investigation + Jira write-up + COLE gates are done. **Issue 1 (this card):** cleanup script ready with a Section 1b backup of the exact deleted rows; the 154 sibling-DB records are KEPT (decision 2026-07-09 — `#keep` excludes them; delete scope = 70,921 true orphans); open item = the 368-package DIML-artifact purge decision, then run Q3 (refresh backup → dry-run → COMMIT; verify 4a=0/4b=154). **Issue 2 (LND-8451 — own repo):** DIML check done and decisive; run `LND-8451_dedupe_xref.sql` (in the LND-8451 repo; dry-run → COMMIT) to single-row the 2,830 live records; optional producer `drop_duplicates` guard. **Issue 3 (LND-8452 — own repo):** correct county on the 2,192 + fix DIML docs for the 668, split shared package_ids, then upload the reprocess CSV for COLE recompute. Not blocked on LND-6879 (driver only). Recurrence prevention (uniqueness guard + package_id-aware classification + delete-cascades-to-xref in cs-digital-mfg) is a separate team follow-up, not implemented here.