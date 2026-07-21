# LND-6796 — Orphaned `RecordID`s in `tblDimlXref`: Root Cause & Findings

**Ticket:** https://enverus.atlassian.net/browse/LND-6796

**Issue:** `[CS_Digital].[dbo].[tblDimlXref]` contains 65,148 `package_id`s mapping to more than one recordID. Under those package_ids sit ~71,075 `RecordID`s with **no matching row in `CS_Digital.dbo.tblRecord`** — orphaned xref rows whose parent records were deleted. A cross-database check (2026-07-02) confirmed **70,921 of the 71,075 are absent from all three courthouse databases** (`CS_Digital`, `countyScansTitle`, `courthousedirecttitle`) — true orphans — **these are the ones deleted**. The remaining 154 (153 in `countyScansTitle`, 1 in `courthousedirecttitle`) exist in a sibling database's `tblRecord` — 3 are actively publishing from there — and per the 2026-07-09 decision are **kept**: their `CS_Digital` xref rows are excluded from the delete (§3).

> The disjoint **duplicate-xref-row** defect (one recordID bound to two `package_id`s — the latent producer-crash population) was split to sub-task **[LND-8451](https://enverus.atlassian.net/browse/LND-8451)**; its write-up, SQL, DIML check, and dedupe tooling live in its own repo **`github.com/donald-massey/LND-8451`** and are not covered here.

---

## 1. The three identifiers

- **`package_id`** — DIML's identifier for a **collection** of datasets tied to one instrument: the source PDF (root `instrument_pdf` dataset) plus derived artifacts (`combined_ocr_result`, `iie_result`). Can hold **multiple `dataset_id`s** — *not* 1:1 with a document.
- **`recordID`** — a row in `tblRecord`: an **instrument record** (`newid()` GUID carrying `countyID`, `recordNumber`, `fileDate`).
- **`tblDimlXref`** — the bridge, `recordID ↔ package_id`: how the producer/COLE know which DIML document to pull for a record.

---

## 2. How the orphans arise — `cs-digital-mfg`

`clerk_load.process_county` mints a `newid()` recordID for each new clerk record and inserts rows into `tblRecord` **and** `tblDimlXref`. When a record is later deleted from `tblRecord`, its `tblDimlXref` row is not always removed with it — leaving an xref row whose recordID no longer exists in `tblRecord`. That is the orphan population.

Writer files (in `cs-digital-mfg`): `mfg/clerk_load.py` (`process_county`), `db/models.py` (`TblDimlXRef.insert/update`).

---

## 3. Findings — orphan cross-database check (2026-07-02)

The orphaned `RecordID`s (absent from `CS_Digital.dbo.tblRecord`) were cross-checked against `dbo.tblRecord` in all three courthouse databases via `LND-6796_orphan_tool.py check` → `LND-6796_shape1_orphan_xdb_results.csv`.

| verdict | count |
|---------|------:|
| `true_orphan` (absent from all three databases) | **70,921** |
| `found_in_countyScansTitle` | 153 |
| `found_in_courthousedirecttitle` | 1 |
| **Total checked** | **71,075** |

**Determination:** 70,921 (99.8%) are true orphans — parent records deleted, xref rows left behind. No live pipeline reads them (the producer only processes records that exist in `tblRecord`), so they are **safe to `DELETE`**.

> Note: 65,148 counts `package_id`s with >1 xref row — **not** records, and **not** "65,148 orphans." The recordIDs under those package_ids are a mix of orphaned and live; this cleanup touches only the orphaned ones (`WHERE NOT EXISTS (… tblRecord …)`).

### Status of the 154 non-orphans

The cross-database check was **diagnostic** — run to establish what actually happened to these records, not to gate the delete. The 154 are absent from `CS_Digital.dbo.tblRecord` but present in a sibling database's `tblRecord`: **153 in `countyScansTitle`, 1 in `courthousedirecttitle`**. Of the 154, **3 are actively being published downstream** — 2 sourced from `countyScansTitle`, 1 from `courthousedirecttitle`.

**Decision (2026-07-09): keep the 154.** Although their leftover `CS_Digital` xref rows are technically dead (the record they once pointed at no longer exists in `CS_Digital.tblRecord`), these records are live and publishing from the sibling databases, so we leave their `CS_Digital` xref rows in place rather than delete them. Only the **70,921 true orphans** are deleted. In the cleanup, Section 1 loads the 154 into a `#keep` list and excludes them from `#orphans`; after the delete they remain present by design (Section 4b confirms the 154 still exist).

---

## 4. How to handle it

Mechanically a **low-risk delete of dead rows**, pending the DIML-artifact decision.

### Which package_ids can be purge candidates?

The delete and the purge are on **two different axes**:

- **recordID axis (the delete)** — all ~71,075 orphaned recordIDs are absent from `CS_Digital.tblRecord`; the cleanup deletes the **70,921** true orphans and **keeps the 154** that live in a sibling DB.
- **package_id axis (the purge)** — a `package_id` may be pointed at by several recordIDs, some orphaned, some live. Deleting an orphaned recordID's xref row says **nothing** about whether the package's DIML files can be purged, since a *live* recordID may still use the same package. Purge candidates are only packages that no live record points at.

`live_record_count` in `LND-6796_shape1_orphans.csv` separates them: per orphaned recordID's `package_id`, it counts how many *other* recordIDs under that package still exist in `CS_Digital.dbo.tblRecord`. `0` = fully orphaned; `>0` = still shared.

| | count | meaning |
|---|---:|---|
| Orphaned recordIDs (absent from `tblRecord`) | **71,075** | 70,921 deleted (true orphans) + 154 kept (live in a sibling DB) |
| ↳ distinct `package_id`s | **63,947** | — |
| &nbsp;&nbsp;↳ fully orphaned (`live_record_count = 0`) | **368** | no live record → DIML files are **purge candidates** |
| &nbsp;&nbsp;↳ shared (`live_record_count > 0`) | **63,579** | a live record still uses it → **do not purge** |

So the purge question concerns only **368** packages, not 64k.

> **OPEN QUESTION (team):** whether to purge the DIML OCR/IIE artifacts under those 368 fully orphaned package_ids, or leave them as harmless stale data. No action without the team's decision.

**Checking which of the 368 still have DIML files.** Scope a batch existence check to the 368 (`live_record_count = 0`, deduped). Reuse `build_client()` in `diml_fetch_package.py` (PROD, presigned fetch, no AWS creds, VPN up) and the `package_info()` pattern from `LND-8451_diml_pdf_check.py` in the LND-8451 repo (one `diml.list_datasets(package_id)` call → root-PDF + OCR/IIE flags). Output `package_id, exists, has_instrument_pdf, has_ocr, has_iie, dataset_count, error` — ~1–2 min.

> **Caveat:** the 368 is derived from `live_record_count` in **CS_Digital only**. A package fully orphaned here could still be referenced by one of the 154 records in the sibling databases. DIML is shared across all three — treat "exists in DIML" as the truth and never purge a package any live record (in any database) still points at.

### Tooling — `LND-6796_primary_issue_orphan_cleanup.sql`

One file, three server-scoped queries (the three DBs are on separate instances):
- **Query 1 / 2 (review only, no delete)** — the 153 records in `countyScansTitle.dbo.tblRecord` and the 1 in `courthousedirecttitle.dbo.tblRecord` (each carries an embedded RecordID list from the xdb-results CSV, since the sibling servers can't reach CS_Digital). Nothing is modified on those servers; these are the 154 we keep.
- **Query 3** — on CS_Digital. **Section 1** builds the orphan set and loads the 154 kept RecordIDs into `#keep`, excluding them → net delete set = the **70,921** true orphans. **Section 1b backs up the exact deletion set** (`SELECT x.*` → save as `backup/LND-6796_shape1_deleted_xref_backup.csv`) before `DELETE`ing those rows (dry-run counts → `BEGIN TRAN` defaulting to `ROLLBACK`, flip to `COMMIT`). Section 4 verifies (4a = 0 deleted orphans remain; 4b = 154 kept rows still present).

**Backup of deleted rows.** Before committing, Section 1b must be run and its result saved as `backup/LND-6796_shape1_deleted_xref_backup.csv` — a full-fidelity, restore-grade copy (all columns, taken from the live table so it is provably the deletion set). Its row count must equal the Section 2a `rows_to_delete` (~70,921). The committed backup CSV has been filtered to exactly that 70,921-row set (the 154 kept RecordIDs removed); re-run Section 1b at delete time to reconfirm against the live table.

> Query 3 deletes the **70,921 true orphans only**. The 154 that still exist in a sibling DB (3 actively publishing) are **kept** — Section 1's `#keep` list excludes them, so their `CS_Digital` xref rows are left in place.

---

## 5. Verification / exit criteria

After Query 3 commits (Section 4):

- **4a** — the deleted orphans are gone: joining `tblDimlXref` to the `#orphans` set returns **0**.
- **4b** — the kept set is intact: joining `tblDimlXref` to `#keep` returns **154**.

A raw `NOT EXISTS (… tblRecord …)` orphan count will now return **154**, not 0 — that is the kept set, by design, not a failure:

```sql
SELECT COUNT(*) AS orphaned_xref_rows   -- expect 154 (the kept set), not 0
FROM [CS_Digital].[dbo].[tblDimlXref] x
WHERE NOT EXISTS (
    SELECT 1 FROM [CS_Digital].[dbo].[tblRecord] r WHERE r.recordID = x.RecordID);
```

---

## 6. Plan

1. ~~**Triage the 154 non-orphans**~~ — done (§3): they live in sibling DBs (3 publishing) and are **kept**, excluded via `#keep`. Only the 70,921 true orphans are deleted.
2. **Resolve the DIML-artifact question** for the 368 fully orphaned packages (optional existence check above).
3. **Run Query 3** — refresh Section 1b backup to the 70,921-row set (save `backup/LND-6796_shape1_deleted_xref_backup.csv`, confirm its row count = 2a `rows_to_delete`), then dry-run → COMMIT.
4. **Verify** — §5: Section 4a = 0, 4b = 154.

*Recurrence prevention (separate cs-digital-mfg follow-up):* ensure a hard-delete of a `tblRecord` row also removes its `tblDimlXref` rows. Being raised with the team.