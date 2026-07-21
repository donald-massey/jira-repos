# LND-8451 — Duplicate `tblDimlXref` rows: one recordID bound to two package_ids (split off from LND-6796)

**~4,500 `CS_Digital.dbo.tblRecord` recordIDs each have two rows in `tblDimlXref` carrying two *different* `package_id`s.** A record should map to one DIML document, not two — a data-integrity defect. This card collapses each affected record back to one xref row, keeping the correct package_id.

**Scope:** ~4,500 recordIDs (~9,000 rows) → **2,830 live** (have a `tblRecord` row) + **1,670 orphaned** (recordID absent from `tblRecord`). A full DIML content check confirmed **all 2,830 live recordIDs point at byte-identical PDFs**, so the scoped dedupe is unconditionally safe for the live population. Disjoint from the two other LND-6796 slices (orphaned xref rows; cross-county correctness).

**No evidence of producer impact:** `land-lease-producer`'s control table `[countyScansTitle].[dbo].[tblDataLoadersPerCounty].[LastProcessedDateLandLeaseProducer]` advances for every county each run, and 22 consecutive clean prod runs (2026-06-09 → 06-30) show no merge explosion. Treat as cleanup, not an outage fix.

---

## 1. Background — how one record gets two package_ids

Records are written by **`cs-digital-mfg`** (`clerk_load.process_county` → `TblDimlXRef.insert`). `TblDimlXRef.insert` (`cs_digital_mfg/db/models.py`) is a **blind `INSERT` with no existence check**, and there is **no unique constraint on `tblDimlXref.recordID`**. So when a later load re-associates an existing record (matched as an UPDATE, reusing its recordID) to a **new** `package_id`, the insert **appends a second row** instead of replacing the first — one recordID, two rows, two package_ids.

These are **not** identical re-run rows: the record is bound to two *distinct* DIML document identifiers, which is why "which package_id is correct" must be checked in DIML before deleting either row.

**Why it can break the producer (latent).** `image_enricher.py` / `iie_enricher.py` query `tblDimlXref` by `recordID` and `pd.merge` onto the instruments DataFrame. Two xref rows **explode** that instrument into two rows; downstream code assumes one row per instrument. This is the failure Denison referenced — but it has not fired in prod (control-table evidence above).

---

## 2. The numbers

| Split | count | meaning |
|-------|------:|---------|
| Duplicate recordIDs | **~4,500** | two xref rows / two package_ids each (~9,000 rows) |
| ↳ **live** (`tblRecord` row) | **2,830** | the only population the producer can pull |
| ↳ **orphaned** (absent from `tblRecord`) | **1,670** | never pulled → dedupe is cleanup only |

**DIML content check — full prod run, 2026-06-30** (`LND-8451_diml_pdf_check.py`, all 4,500 pairs, 0 errors), cross-tabbed against the live/orphan split:

| population | verdict | count |
|------------|---------|------:|
| **live** | `same_pdf` | **2,830** |
| orphan | `same_pdf` | 1,633 |
| orphan | `different_pdf` | 12 |
| orphan | `missing_pdf` | 25 |

**Every live recordID is `same_pdf`** (both package_ids point at the same document → collapsing can't bind a wrong document). **All 37 ambiguous records** (12 `different_pdf` + 25 `missing_pdf`) are **orphans**, so none is producer-relevant. The content check earned its keep: 8 of the 12 `different_pdf` are same-size/different-ETag — a path-only comparison would have missed them *and* falsely flagged all 4,463 `same_pdf` (every DIML key embeds its own package/dataset id).

---

## 3. How the records were identified

All SQL is in **`identify_duplicate_xref_records.sql`** (self-contained, CS_Digital only):

1. **A — duplicate xref rows** (`GROUP BY RecordID HAVING COUNT(*) > 1`) → `LND-8451(C).csv`.
2. **B — Shape 2 pairs** — pivots each recordID to `package_id_1` / `package_id_2` with context → `shape2_pairs.csv`, the DIML-check input. `LEFT JOIN` keeps the 1,670 orphans (context NULL).
3. **C — live vs orphan split** — quantifies 2,830 / 1,670 and probes one missing id (exact + normalized) to confirm genuine orphans, not a collation artifact.

---

## 4. Artifacts

| File | What |
|------|------|
| `identify_duplicate_xref_records.sql` | duplicate detection + Shape 2 pivot + live/orphan split |
| `LND-8451_diml_pdf_check.py` | DIML **content** check: compares each pair's root `instrument_pdf` by S3 size + ETag (hashes ambiguous multipart), not the URL path. Writes verdict + OCR/IIE flags + `keep_package_id`. Prod-only, presigned fetch (no AWS creds), VPN. Run with `.\.venv\Scripts\python.exe` |
| `LND-8451_dedupe_xref.sql` | Self-contained, dry-run-first dedupe scoped to the `same_pdf` set. Inlines `#exclude` (37 ambiguous) + `#override` (20 artifact-winner keepers); the rest fall back to latest `_ModifiedDateTime` |
| `LND-8451(C).csv` | duplicate xref rows — ~9,000 rows / ~4,500 recordIDs |
| `shape2_pairs.csv` | Shape 2 pivot — DIML-check input |
| `shape2_pdf_compare.csv` | DIML-check output — verdict + flags + `keep_package_id`. **Source of truth** for the dedupe's inline lists |

---

## 5. Fix path

**Optional defensive guard (zero data risk).** Add `drop_duplicates` after the `get_package_ids` merge in `image_enricher.py` / `iie_enricher.py`:

```python
package_ids = get_package_ids(instruments[instrument_id_column_name].tolist())
instruments = pd.merge(instruments, package_ids, how="left", on=instrument_id_column_name)
instruments = instruments.drop_duplicates(subset=[instrument_id_column_name])  # LND-8451: guard against dup xref rows
```

Guarantees one row per instrument if a duplicate is ever pulled. Keeps one package_id arbitrarily (pandas keeps first) — but since all 2,830 live records are `same_pdf`, even the arbitrary keep is document-correct. Belt-and-suspenders, not required.

**The dedupe — end to end:**

1. **Pull the pairs → `shape2_pairs.csv`** (Step B of `identify_duplicate_xref_records.sql`, no `TOP`).
2. **Classify in DIML → `LND-8451_diml_pdf_check.py`** (read-only). Fingerprints each package's root `instrument_pdf` by S3 **content** (size + ETag, hashing only the ambiguous multipart case) — not the URL path, which always differs because it embeds the package/dataset id. Verdicts:
   - **`same_pdf`** → safe; also picks `keep_package_id` = package with more complete OCR+IIE (blank on a tie → SQL falls back to latest `_ModifiedDateTime`).
   - **`different_pdf`** → do **not** auto-dedupe; resolve first. (All 12 are orphans.)
   - **`same_size_unverified` / `missing_pdf` / `lookup_error`** → excluded.
3. **Dedupe → `LND-8451_dedupe_xref.sql`** (self-contained). Inlines `#exclude` (37 ambiguous) + `#override` (20 keepers) from `shape2_pdf_compare.csv`; the ~4,443 rest derive at runtime. Builds the plan, previews (dry-run counts + sample), then `DELETE`s in a transaction defaulting to `ROLLBACK` — review, flip to `COMMIT`. Post-check asserts one row per record.

   > ⚠️ Do **not** run a blanket `DELETE … WHERE rn > 1` over all of `tblDimlXref` — it would collapse `different_pdf` records and any multi-row recordIDs outside the 4,500. The script scopes strictly to the confirmed `same_pdf` set.

**Net:** running the dedupe single-rows all 2,830 live records (no document resolution needed) plus 1,633 `same_pdf` orphans (cleanup). The 37 ambiguous orphans stay untouched.

---

## 6. Open items

- **Dedupe the 1,670 orphaned xref rows?** (owner → team, not urgent) — deduping makes the exit check return 0 cleanly; leaving them means verifying against the live-only count. The tooling handles both (keys on recordID). Don't act without go-ahead.
- **`same_size_unverified` / `missing_pdf` / `lookup_error`** — investigated separately; all orphans in current data, so none blocks the live-set dedupe.

---

## 7. Verification / exit criteria

After deduping, assert **0 rows**:

```sql
-- all duplicate recordIDs (0 only after deduping same_pdf AND cleaning/resolving the rest)
SELECT COUNT(*) AS multi_row_recordIDs FROM (
    SELECT RecordID FROM [CS_Digital].[dbo].[tblDimlXref]
    GROUP BY RecordID HAVING COUNT(*) > 1) q;

-- live-only variant: excludes the 1,670 orphaned rows. Use if orphans are left as-is.
SELECT COUNT(*) AS multi_row_live_recordIDs FROM (
    SELECT x.RecordID
    FROM [CS_Digital].[dbo].[tblDimlXref] x
    JOIN [CS_Digital].[dbo].[tblRecord] r ON r.recordID = x.RecordID
    GROUP BY x.RecordID HAVING COUNT(*) > 1) q;
```

The producer control table should keep advancing every county (already true) — the dedupe just removes the latent duplicate binding on the 2,830 live recordIDs.

---

## 8. Dependencies & recurrence prevention

No hard dependencies — the DIML check is run, the verdict is decisive, the dedupe can proceed now; the `drop_duplicates` guard is standalone.

*Recurrence prevention (separate cs-digital-mfg follow-up):* add a uniqueness guard on `tblDimlXref.recordID` (or an existence check in `TblDimlXRef.insert`) so a re-association replaces the row instead of appending. Being raised with the team.