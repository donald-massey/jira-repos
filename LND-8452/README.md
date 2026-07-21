# LND-8452 — Cross-county / different-document correctness (split off from LND-6796)

One DIML `package_id` (one underlying instrument PDF) is pointed at by **several `CS_Digital.dbo.tblRecord` records that disagree on county and/or document**. Where they disagree on county, at least one record carries the **wrong county**, so COLE/IIE resolves land descriptions against the wrong county and produces wrong results. This card corrects those records and re-computes them through COLE.

**Scope:** 2,307 affected `package_id`s → **4,838 distinct records**, 100% Oklahoma. The *correctness* slice of LND-6796, disjoint from the two cleanup slices (orphaned xref rows; duplicate xref rows) that stayed on the parent card.

---

## 1. Background — how one document lands under two counties

Records are written by **`cs-digital-mfg`** (`clerk_load.process_county` → `TblDimlXRef.insert`). The loader classifies insert-vs-update by matching `tblRecord` on `(StateID, CountyID, normalized recordNumber, fileDate)`, county derived from the scraper's `diml_county_name`. **`package_id` is not in the match key**, and every "new" record gets a fresh `newid()` recordID.

So when the same document (same `package_id`) is re-scraped under a **different** county — because the upstream scraper's county assignment is unstable (**LND-6879**) — the county-scoped match misses the prior record, classifies it NEW, and mints a second recordID under the new county. One `package_id` now maps to two records in two counties for one PDF; at least one county is wrong.

`handle_image` (`images.py`) also uploads a **per-record copy** of the PDF to a county-specific S3 key at creation, so the wrong-county run writes a byte-identical copy under the wrong county's folder. The bytes are correct; the folder and the record it's tied to are wrong.

**Why it breaks IIE/LLM:** land descriptions (abstracts, surveys, blocks) are **county-specific**. If a record says county B but the document is really county A, IIE resolves the legal descriptions against the wrong county → wrong land descriptions → wrong IIE, and the LLM summary inherits the error.

---

## 2. The two shapes

| Shape | package_ids | What's wrong | Breakdown |
|-------|-------------|--------------|-----------|
| **(b) different county** | **2,192** | records span >1 county for one package_id | 2,113 across 2 · 71 across 3 · 8 across 4 |
| **(a) different document** | **668** | records point at >1 DIML document for one package_id | 625 with 2 docs · 39 with 3 · 4 with 4 |
| **Union (COLE candidate set)** | **2,307** | — | resolves to **4,838 distinct records** |

The two overlap: of the 2,307, **553 fail both**, 1,639 are county-only, 115 are document-only — so a single record can need both a county fix and a document fix.

> **(a) is a proxy** — detected via distinct `originalFileName` (= `{package_id, dataset_id}`) within a group. A package can legitimately hold several datasets, so a differing `dataset_id` alone doesn't prove different PDFs; confirm a genuine byte difference in DIML (root `instrument_pdf`, S3 size + ETag) before acting.

Every affected record has a live `tblRecord` row and its own children (`tblGrantorGrantee`, `tblLandDescription`, `tbldeedReference*`, `tblRecordIIE`) plus Kafka/ES consumers. **These are legitimate published records, not mechanical duplicates — they must be corrected and re-computed, not deleted as "dupes."**

---

## 3. How the records were identified

All SQL is in **`identify_correctness_records.sql`** (self-contained). Run Section 0 first, then the rest in the same SSMS window (`#affected_records` is session-scoped):

1. **Section 0 — staging.** Pre-filter `tblDimlXref` to `package_id`s with >1 row, then INNER JOIN to `tblRecord` once into `#affected_records`. The INNER JOIN is what scopes this to **live** records.
2. **(a) different document** — `HAVING COUNT(DISTINCT originalFileName) > 1`.
3. **(b) different county** — `HAVING COUNT(DISTINCT CountyID) > 1`.
4. **COLE fixed dataset** — union of (a) ∪ (b) as `recordID, countyName, stateAbbreviation, imageLocation` (`imageLocation = LOWER(ISNULL(tblS3Image.s3FilePath, tblRecord.storageFilePath))`).

All 4,838 records are Oklahoma, corroborating LND-6879 (the OKCR scraper) as the driver.

---

## 4. Artifacts

| File | What |
|------|------|
| `identify_correctness_records.sql` | staging + (a) + (b) + COLE union |
| `LND-6796(B).csv` | (b) different-county — 2,192 package_ids |
| `LND-6796(A).csv` | (a) different-document — 668 package_ids |
| `LND-6796_reprocess_records_20260629T194433Z.csv` | COLE fixed dataset — 4,838 records |

---

## 5. Fix path

A COLE recompute is only as correct as two inputs it does **not** derive for itself, both confirmed from the COLE code (`land.courthouse-ocr-legals-extractor`):

- **County — IIE trusts the supplied `countyName`.** No document-based county detection; `SingleChunkIIEProcessor` feeds the supplied county straight to the engine. ⇒ `tblRecord.countyID` must be corrected **before** recompute.
- **Document — OCR re-pulls the PDF from DIML by `package_id`.** `imageLocation` is only a fallback when DIML has no root PDF. ⇒ different-document records must be fixed at the **DIML package→PDF binding**, not via `imageLocation`.

Feeding the 4,838-record dataset as-built just reproduces today's wrong answers. Ordered plan:

1. **Correct the county on the 2,192 cross-county records** — fix `tblRecord.countyID` to the true county (or soft-delete the wrong-county record). IIE will not self-correct.
2. **Fix the document binding for the ~668** — confirm a real byte difference in DIML first; where documents differ, make the correct PDF the `instrument_pdf` root or re-bind the record to a correct package_id. Correcting `imageLocation` alone does nothing.
3. **Split shared package_ids before recompute** — OCR/IIE artifacts are keyed by `package_id`, so two records sharing one write to the same artifact set (recompute → last writer wins). Delete the shared xref rows so COLE mints a fresh per-record package_id and OCRs each record's own image.
4. **Recompute via COLE** — upload the union CSV to `s3://land-{dev,prod}/data/courthouse-ocr-legals-extractor/fixed_dataset/hardcoded_input/`. Do this **after** steps 1–3. Not gated on LND-6879 (see Dependencies).

---

## 6. Open items

- **True-county source of truth (needed for step 1).** No confirmed per-record source for the *correct* county yet. The in-house option — an OCR-header `COUNTY OF …` extraction — is self-sufficient and waits on nothing; the corrected OKCR feed (LND-6879) is an alternative if/when available.
- **Correct-document determination (step 2).** The authoritative per-record answer is the record's **own image** (`tblS3Image.s3FilePath` / `tblRecord.storageFilePath`); compare candidates against it.
- **Per-record COLE artifacts.** LND-6792 made COLE *tolerate* a shared package_id but recompute is not per-record — confirm with the COLE owner whether per-record artifacts are expected after the step-3 split.

---

## 7. Dependencies

- **LND-6879** (OKCR scraper loading to wrong counties) — the upstream root-cause driver, **not a blocker**. This correction can be done at any time, independently of LND-6879. Note only: 6879 stops *new* wrong-county records going forward, and if it back-tags existing OK records, re-measure first since some of the 2,307 may self-resolve.
- **LND-6792** — COLE fixed to tolerate a `package_id` shared across recordIDs. Pre-req complete.
- *Recurrence prevention (separate cs-digital-mfg follow-up):* make the insert-vs-update classification `package_id`-aware, so a known document reconciles to its existing record instead of minting a new cross-county one.