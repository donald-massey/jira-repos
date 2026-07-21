# LND-6796 — `tblDimlXref` shared/duplicate `package_id`

**Ticket:** https://enverus.atlassian.net/browse/LND-6796
**Scope of this repo:** Issue 1 — orphaned `RecordID`s in `[CS_Digital].[dbo].[tblDimlXref]`.

`tblDimlXref` bridges a DIML `package_id` (the OCR/IIE artifacts for an instrument) to a
`RecordID` in `tblRecord`. The card's headline — **65,148 `package_id`s mapping to more than
one `RecordID`** — decomposes into three disjoint problems. Two were split to their own tickets
and repos; **this repo carries only Issue 1.**

| Slice | What | Where |
|-------|------|-------|
| **Issue 1 — orphans** | ~71,075 `RecordID`s under multi-record `package_id`s that are absent from `CS_Digital.dbo.tblRecord` (parent records hard-deleted, xref rows left behind). | **this repo** |
| Issue 2 — duplicate xref rows | One `RecordID` bound to two `package_id`s (the latent land-lease-producer crash population). | [`github.com/donald-massey/LND-8451`](https://github.com/donald-massey/LND-8451) · [LND-8451](https://enverus.atlassian.net/browse/LND-8451) |
| Issue 3 — cross-county / different-doc | One `package_id` pointed at by many `RecordID`s across counties/documents (correctness for COLE recompute). | [`github.com/donald-massey/LND-8452`](https://github.com/donald-massey/LND-8452) · [LND-8452](https://enverus.atlassian.net/browse/LND-8452) |

The three are independent and can be run in any order. `65,148` counts *package_ids with >1 xref
row* — not records; the RecordIDs under them are a mix of orphaned and live.

## The orphan issue

`cs-digital-mfg` (`clerk_load.process_county`) writes rows to `tblRecord` and `tblDimlXref`
together. When a record is later hard-deleted from `tblRecord`, its `tblDimlXref` row is not
always removed — leaving an xref row whose `RecordID` no longer exists in `tblRecord`.

**Cross-database check (2026-07-02)** — each orphaned `RecordID` was looked up in `dbo.tblRecord`
across all three courthouse databases:

| verdict | count | disposition |
|---------|------:|-------------|
| `true_orphan` (absent from all three DBs) | **70,921** | dead rows — **deleted** |
| `found_in_countyScansTitle` | 153 | live in sibling DB (2 actively publishing) — **kept** |
| `found_in_courthousedirecttitle` | 1 | live in sibling DB (1 actively publishing) — **kept** |
| **Total** | **71,075** | delete scope = 70,921 |

**Delete scope: the 70,921 true orphans only.** The **154 non-orphans** exist in a *sibling*
database's `tblRecord` (3 of them still publish downstream), so we **keep** their `CS_Digital` xref
rows rather than delete them. Section 1 of the cleanup loads those 154 into a `#keep` list and
excludes them from the delete set. Details and the dev-facing status writeup:
`LND-6796_ISSUE_AND_FIX.md`.

**DIML-artifact purge (open question).** Of the 63,947 distinct `package_id`s under the orphans,
only **368** are fully orphaned (`live_record_count = 0`) — DIML purge candidates. The other
63,579 are still shared with a live record; do not purge those. Whether to purge the 368 is a
team decision, not actioned here.

## Files

Scripts, SQL, and docs live at the repo root; the data CSVs live in `csv/`.

**The writeup**
| File | What it is |
|------|------------|
| `LND-6796_ISSUE_AND_FIX.md` | Root cause, cross-DB findings, and the dev-facing status of the 154 non-orphans. The narrative to read first. |
| `README.md` | This file. |
| `CLAUDE.md` | Working notes / context for the whole three-slice investigation (Issues 1–3). |

**Tooling**
| File | What it does |
|------|--------------|
| `LND-6796_orphan_tool.py` | `check` — looks up every orphaned `RecordID` in `tblRecord` across all three DBs and writes the verdict CSV. `export` — dumps full record detail for the 154 non-orphans, one CSV per sibling DB. Paths resolve relative to the script, so it runs from any cwd. |
| `LND-6796_primary_issue_orphan_cleanup.sql` | The cleanup. Q1/Q2 pull the 153/1 sibling-DB records (run on their own servers); Q3 re-derives the orphan set on CS_Digital, Section 1b backs up the exact deletion set, then `DELETE`s (dry-run → `COMMIT`). |
| `LND-6796.sql` | Original identification queries — how the orphan set and the 65,148 headline were first derived. |
| `diml_fetch_package.py` | `build_client()` — PROD `DimlApi` with presigned fetch (no AWS creds). Reused for the optional 368-package DIML existence check. |

**Data** (all in `csv/`)
| File | Contents |
|------|----------|
| `csv/LND-6796_shape1_orphans.csv` | 71,075 rows: `package_id, orphaned_RecordID, live_record_count`. Input to `check`; drives the 368 purge-candidate count. |
| `csv/LND-6796_shape1_orphan_xdb_results.csv` | Per-`RecordID` verdict across the three DBs (`true_orphan` / `found_in_*`). Output of `check`, input to `export` and the cleanup SQL. |
| `csv/LND-6796_shape1_records.csv` | Full record detail for the orphaned set (supporting data). |
| `csv/LND-6796_orphans_countyScansTitle.csv` | The 153 non-orphans' detail from `countyScansTitle`. Output of `export`. |
| `csv/LND-6796_orphans_courthousedirecttitle.csv` | The 1 non-orphan's detail from `courthousedirecttitle`. Output of `export`. |

**Notes / config**
| File | What it is |
|------|------------|
| `results.txt` | Open-item walk-through from the full investigation (COLE gates, DIML check, prod status). |
| `review.md` | Scratch review notes. |
| `requirements.txt` | `python-dateutil`, `pyodbc`, `python-dotenv`, `diml-api-helper@1.1.8` (SSH to git.drillinginfo.com). |
| `.env.example` | Template for the connection env vars — copy to `.env` and fill in. |
| `backup/` | Holds `LND-6796_shape1_deleted_xref_backup.csv` — the restore-grade backup of the deleted rows, produced by running Section 1b of the cleanup SQL before the `DELETE` commits. |

## Running the tooling

Requires VPN. `pip install -r requirements.txt` (needs SSH to `git.drillinginfo.com` for
`diml-api-helper`), then copy `.env.example` → `.env` and fill in the connection vars.

```powershell
# from the repo root (where .venv lives)
.\.venv\Scripts\python.exe LND-6796_orphan_tool.py check    # -> xdb_results.csv
.\.venv\Scripts\python.exe LND-6796_orphan_tool.py export   # -> per-DB detail CSVs
```

- **`check`** — reads `LND-6796_shape1_orphans.csv`, looks up each orphaned `RecordID` in
  `dbo.tblRecord` on all three DBs, writes the verdict CSV.
- **`export`** — reads the verdict CSV and dumps full record detail for the 154 non-orphans, one
  CSV per sibling DB (the two servers can't be exported from one SSMS window).

**Cleanup** — `LND-6796_primary_issue_orphan_cleanup.sql` runs per server (no linked server):
Q1/Q2 **review only** the 153/1 sibling-DB records (nothing is deleted there); Q3 runs on
CS_Digital. **Section 0** lists the surviving live records that stay bound to the affected
package_ids (what stays vs what goes); **Section 1** builds the orphan set and loads the 154 kept
RecordIDs into `#keep`, excluding them — net delete set = the **70,921 true orphans**; **Section 1b
backs up the exact deletion set** — `SELECT x.*` (all `tblDimlXref` columns) → save as
`backup/LND-6796_shape1_deleted_xref_backup.csv` — before the `DELETE` (dry-run counts →
`BEGIN TRAN` defaulting to `ROLLBACK`; flip to `COMMIT`). The backup row count must equal
`rows_to_delete` from Section 2a (~70,921). The committed backup CSV has been filtered to exactly
that 70,921-row set (the 154 kept RecordIDs removed); re-run Section 1b at delete time to reconfirm
against the live table.

## Databases

Three **separate** SQL Server instances — no linked server, no three-part naming; each query runs
on its own connection. Credentials in Consul KV / MyGlue.

| DB | Server | Auth |
|----|--------|------|
| `CS_Digital` | `aus2-ch2-petl01v.na.drillinginfo.com` | Windows |
| `countyScansTitle` | `AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM` | Windows |
| `courthousedirecttitle` | `chddb-prod.cg8t5z7xvisu.us-east-1.rds.amazonaws.com` (RDS) | SQL |

## Status

Investigation and the 154-record triage are done — the 154 are **kept** (excluded via `#keep`);
only the 70,921 true orphans are deleted. Remaining: the 368-package DIML-artifact purge decision
(team), then run Q3 (refresh Section 1b backup → dry-run → COMMIT) and verify Section 4 (4a = 0
deleted orphans remain; 4b = 154 kept rows still present). Recurrence prevention
(delete-cascades-to-xref in `cs-digital-mfg`) is a separate team follow-up.
