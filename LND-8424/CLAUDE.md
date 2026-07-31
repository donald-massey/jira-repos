# LND-8424: Recent CA LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8424
**Linked:** https://enverus.atlassian.net/browse/LND-8426
**Status:** In Progress

Max Lease Date search for MERCED, CA county showed that the max lease date is behind our most recent published leases.

**Important Note:** This record contains two distinct Record IDs and file dates. Due to the image quality, I was unable to confidently determine which file date is accurate.

RecordNumber: 2024017111
File date: 2024-07-20
RecordID: 90c3e6e1-263c-4470-92c2-652f03092842
Div1_LeaseID: 5067911

RecordNumber: 2024017111
File date: 2024-07-23
RecordID: c5d14542-c2ea-4a4a-8532-0936227ad2ec

## Approach

**Method:** Follow the published **Missing Legal Leases Investigation Runbook (LND-8426)** —
https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284. This is the go-forward standard
for every "recent legal leases not published" card. Queries are instantiated from
`jira-repos/_lease-investigation-template/` and live in `query_1..query_4` (author-only SQL/PS1;
run in SSMS / on the IIF share).

Two-level flow, run in order. Do not skip to Level 2.

### Facts established during planning
- **Source system:** MERCED, CA is sourced from **CSTitle** (`cstitle_lease_data_provider`). The two GUID `RecordID`s are the real CSTitle records; `Div1_LeaseID 5067911` is the legacy key.
- **mapping_id gate is DIV1-side even for CSTitle counties.** Glue's `legal_lease` writer drops any record with `mapping_id IS NULL`; `mapping_id` = `land_descriptions[].legacy_mapping_id`, sourced from DIV1 `tblleaseAbstractMapping.mappingid`. For CSTitle-sourced records, `cstitle_lease_data_provider._enrich_land_descriptions_by_div1_legacy_fields()` matches the CSTitle `tblLandDescription` rows against DIV1 land descriptions for the same LeaseID and copies `legacy_mapping_id` across — **no DIV1 mapping for LeaseID 5067911 → no mapping_id → dropped.** CA is a base-path state (StateID NOT IN 91/102/93); no parcel/`TblAddsFields` match involved.
- **Known code smell (note, don't fix blindly):** StatusID lists are inconsistent — `cstitle_get_modified_instrument_ids.sql` emits `(4,10,16)`, but `is_active` in `cstitle_get_instruments.sql` only maps `(4,10)`→1 / `11`→0, so StatusID 16 → NULL `is_active`. Check both records' `statusID` in query_1; if 16, reconcile query_4's `(4,10)` candidate universe to `(4,10,16)`.

### Level 1 — ch-lease-exporter / IIF Lease Importer  (`query_1`, START HERE)
Check `countyScansTitle.dbo.tblexportLog` for both RecordIDs. `leaseID NOT NULL` → matched, go to Level 2. `leaseID NULL` → IIF never created the DIV1 row (usually the 08:00–22:00 CST business-hours timing race); confirm in the IIF log (`iif_log_search.ps1`), quantify the batch by `zipName`, remediate with `DELETE ... WHERE zipName` after verifying `statusID IN (4,16)`. No row → not yet exported.

**PDF visual review (`pdf_visual_review.md`) — mandatory Level 1 step.** After `compare_duplicate_records.sql` + `doc_image_paths.sql`, open both PDFs from their UNC paths and eyeball them. SQL fields only *suggest* duplicate-vs-distinct; the images settle it, and they're the only way to know whether the document even *carries a parseable legal* (section/township/range, abstract/survey, or metes-and-bounds — a street address + acreage is not one). This decides remediation shape: duplicate → remediate only the record that reached DIV1; no parseable legal → COLE reprocess won't populate descriptions, so manual land-desc entry, not reprocess + re-export.

### Level 2 — producer → glue  (`query_2`)
Only after Level 1 passes. Check DIV1 `tblleaseAbstractMapping` for LeaseID 5067911 (the mapping_id source), CSTitle `tblLandDescription` for both RecordIDs, and the ES `legal_lease` index (`es_legal_lease_check.json`) — absent vs older version. No mapping / no descriptions → upstream courthouse legal-extraction gap → COLE check.

### COLE check  (`query_3`)
Splits reprocess candidate (queue miss / failed OCR-IIE, or image overwritten after COLE ran) from document-type limitation (COLE ran clean, document has no parseable legal). Run per the two RecordIDs.

### Scale  (`query_4`)
Drop-rate for CA (runbook baseline 2.59%, 80/3,088) and MERCED sizing — is this a one-off or a county pattern? If systemic, widen scope to all affected MERCED/CA records.

### Dedup decision — reframed after Level 1 (the collision assumption was wrong)
The earlier assumption — both RecordIDs backfill to leaseId 5067911 and collide on the Kafka key — is disproven. Level 1 shows only 90c3e6e1 has leaseId 5067911; c5d14542 has leaseId NULL (no DIV1 row exists), so there is no key collision. The open question is upstream: are these **one instrument entered twice** (duplicate) or two distinct filings? `compare_duplicate_records.sql` decides it. Working hypothesis: duplicate — one courthouse instrument, one DIV1 lease (5067911), and c5d14542's NULL is the natural-key match-back losing to 90c3e6e1. If so, c5d14542 needs no re-export (re-exporting would dupe the lease); the fix is Level 2 on 90c3e6e1.

### Done criterion (draft — confirm after diagnosis)
RecordNumber 2024017111 visible on the website for MERCED, CA with the correct file date, and MERCED's max lease date matches the CSTitle source max. If the cause is systemic (missing mappings across a migrated county), widen scope to all affected MERCED/CA records.

## Completed

**Level 1 (query_1) — run 2026-07-31.**
- 90c3e6e1 (file date 2024-07-20): leaseID **5067911**, statusID 4, MOGL, vol/page NULL. PASSED Level 1 → its non-publication is a Level 2 issue. Next: query_2.
- c5d14542 (file date 2024-07-23): leaseID **NULL** (both rows), statusID 4, MOGL, vol/page NULL. FAILED Level 1.
- Batch impact: both zips `CH_08.31.2024.17.00/17.01_leases` = 184 records, **183 matched / 1 NULL** each; the 1 NULL is c5d14542. So NOT a timing race (that's all-or-nothing) — it's a per-record match failure. Both zips carry only this one NULL, so a batch re-export would touch 183 already-matched records for no reason.
- Cross-batch timeline: c5d14542 was in the **08-31** batch (matched leaseIDs there ran ~5066707–5067172) → NULL. 90c3e6e1's leaseID **5067911** is well above that ceiling and came from the later **09-04** zip. So c5d14542 failed on its own on 08-31, *before* the same RN landed in DIV1 (as 5067911) via 90c3e6e1 on 09-04 — not a "90c3e6e1 claimed the key first" collision. Remediating c5d14542 now would either bind it to the existing 5067911 (reviving a producer dedup collision) or spawn a second DIV1 lease.
- Next: `compare_duplicate_records.sql` (duplicate vs distinct) and `iif_log_search.ps1` week 2024-35 (per-record import error vs clean match-back miss), then query_2 for lease 5067911.

**Duplicate check (compare_duplicate_records.sql + pdf_visual_review.md) — run 2026-07-31. CORRECTED: DUPLICATE — two scans of one instrument.**
- SQL fields alone *suggested* distinct (grantee 58 vs 59, recordDate 07-20 vs 07-23, effectiveDate 2024-07-18 vs 2023-01-01, image sizes 884,986 vs 526,535). The PDF review overturned that.
- **PDF review verdict — SAME instrument.** Both images are Doc# **2024017111**, recorded 07/22/2024 12:38 PM, Matt H. May / Merced County, same barcode `*S100005986423*`, same recorder block (Titles 1 / Pages 4 / PAID 98.00), same Memorandum-of-Lease body: Tenant GURU ARDAAS INC (Prabhjot Singh, President), Landlord **59 PETROLEUM LLC** (Inderjeet Singh, Manager), premises 3101 N. Hwy 59 Merced, ground lease 1-1-2023, signed 18 July 2024. 90c3 is a heavier scan (more moiré → larger file); c5d1 a lighter scan of the same page.
- **"58 vs 59 PETROLEUM LLC" is a metadata/keying error, not a real difference** — both images clearly read **59**. So the earlier "likely DISTINCT leases" verdict is WRONG. c5d14542 is a duplicate; remediating it would create a duplicate lease → **c5d14542 needs no separate action**; work only 90c3e6e1 (lease 5067911).
- **No parseable legal in the document.** Only land reference is a street address + acreage: "3101 N. Hwy 59 Merced, CA 95348, consisting of approximately 1.38 acres." No section/township/range, no metes-and-bounds, no abstract/survey → the empty `tblLandDescription` is a **document-type limitation (COLUMBIA-like)**, not purely the COLE "No pdf available" error. A COLE reprocess of the now-staged PDF will likely still yield nothing mappable → remediation is **manual land-desc entry** (or accept as no-legal), not reprocess + re-export.
- **PRIMARY BLOCKER — both records have ZERO tblLandDescription rows.** So even 90c3e6e1 (lease 5067911, passed Level 1) is dropped at glue for no mapping_id. Same as LND-8426 COLUMBIA: upstream legal-extraction gap, independent of Level 1.
- Both images `_ModifiedDateTime` 2026-06-16/17 — same window as LND-8426 COLUMBIA's cs_updates overwrite (2026-06-17).

**Level 2 (query_2) — run 2026-07-31. Mapping_id gap CONFIRMED.**
- A (DIV1 `tblleaseAbstractMapping` for 5067911 via LinktoDiv1Repl): **0 rows** — no legacy_mapping_id source in DIV1.
- B (CSTitle `tblLandDescription`, both recordIDs): **0 rows** — no base land descriptions.
- Verdict: lease 5067911 has no mapping_id anywhere → glue drops it from `legal_lease` by design. LND-8426 COLUMBIA pattern confirmed — upstream courthouse legal-extraction gap, not a pipeline bug. Same conclusion applies to c5d14542 (also no land descriptions), so remediating its Level 1 miss wouldn't publish it either.

**COLE (query_3) — run 2026-07-31. ROOT CAUSE: COLE reprocess candidate (recoverable — NOT the COLUMBIA outcome).**
- package_ids: 90c3e6e1 → `cv81nqvk7seg00epplng`; c5d14542 → `cv81nssu5sig00bek9v0`.
- COLE log (both): `OCRErrorMessage = "No pdf available"`, IIE never ran (`_IIEModifiedDateTime` NULL, `OCRs3Path` NULL), OCR attempted **2025-03-11**. COLE failed because no PDF was staged at that time.
- Staleness: `image_newer_than_cole = 1`, **~463 days**. cs_updates staged/overwrote the PDF **2026-06-16/17** — long after COLE's failed run. The current PDF has never been OCR'd.
- tblLandDescription cross-check: empty (COLE produced nothing).
- Verdict: distinct from COLUMBIA (which ran clean on a map-only doc = document-type limitation). Here COLE errored on a missing file and was never retriggered after the file landed.
- **CORRECTED by PDF review (2026-07-31):** the document carries **no parseable legal** (street address + acreage only). So even though COLE never OCR'd the staged PDF, a reprocess would likely still produce zero land descriptions — this is *also* a document-type limitation, converging with COLUMBIA. COLE reprocess is worth attempting but is NOT expected to be sufficient; plan on manual land-desc entry.

**IMPORTANT lineage correction — mapping_id is created by IIF/DIV1, NOT COLE.**
- COLE/IIE → CSTitle `tblLandDescription` (courthouse legal extraction; query_2 B empty).
- IIF Lease Importer → DIV1 `tblLegalLease` + `tblleaseAbstractMapping.mappingid` = the `mapping_id` (query_2 A empty).
- Full chain: COLE extracts legal → CSTitle `tblLandDescription` → ch-lease-exporter DIL → IIF import → DIV1 `tblleaseAbstractMapping` → `mapping_id` → publish. Broken at the top (COLE never OCR'd a present PDF), so nothing propagated to an IIF-created mapping.
- Timeline: lease 5067911 imported by IIF 2024-09-04 with no legal → no abstract mapping. COLE errored 2025-03-11 ("No pdf available"). PDF staged by cs_updates 2026-06-17; COLE never re-ran.
- Therefore the fix is TWO-part, not just COLE: (1) reprocess COLE to populate the CSTitle legal *if* the PDF contains one, then (2) re-export/re-import so IIF creates the DIV1 abstract mapping. COLE alone is necessary-not-sufficient.
- RESOLVED (ch-lease-exporter code): the DIL carries the legal. `ch_lease_exporter/queries.py:161` LEFT JOINs `countyScansTitle.dbo.tbllandDescription` (IsDeleted=0); `lease.py` serializes it into the DIL CSV columns `Surveys(STR)`, `Surveys(Abstract)`, `SurveysDescription`, `Remarks`, `Land Desc. N/A`, PA/OH/WV parcels. IIF imports that and builds the DIV1 lease + `tblleaseAbstractMapping`. So the abstract mapping is downstream of CSTitle `tblLandDescription`.
- Consequence: **recreating/re-exporting the DIL zip now will NOT help** — `tblLandDescription` is empty, so the DIL would carry "Land Data Not Available" and IIF would again create no mapping. The zip only serializes current CSTitle state. The legal must exist in CSTitle first.
- Confirmed fix ORDER: (1) populate CSTitle `tblLandDescription` (COLE reprocess of the now-staged PDF if it has a parseable legal, else manual entry); (2) re-export via ch-lease-exporter so the DIL carries the survey/abstract; (3) IIF import creates `tblleaseAbstractMapping` → mapping_id; (4) producer → glue publishes. Re-export (step 2, prod action into the IIF input share) only after step 1.
- Likely SYSTEMIC: the 2026-06-16/17 cs_updates staging matches LND-8426 COLUMBIA and the Cibola publish-gap pattern. Signature: COLE `"No pdf available"` (early-2025) + image `_ModifiedBy = cs_updates` newer than OCR + zero land descriptions.

**Next steps:**
1. ~~Eyeball both PDFs — confirm parseable legals; settle 58 vs 59.~~ **DONE 2026-07-31** (`pdf_visual_review.md`): duplicate scans of one instrument, both 59 PETROLEUM LLC, no parseable legal.
2. Confirm the IIF → `tblleaseAbstractMapping` mechanism (the OPEN item above) — this drives the remediation shape.
3. Quantify the batch — `query_4/cole_nopdf_signature.sql`, MERCED then CA-wide. Determines one-off vs bulk (feeds the CH3.0 reprocess process; see [[reference-ch3-county-investigation]]). Note: the no-parseable-legal finding means some of that batch may be document-type-limited, not COLE-recoverable — sample a few PDFs before assuming bulk reprocess fixes them.
4. Remediate 90c3e6e1 only (c5d14542 is a duplicate): attempt COLE reprocess of the staged PDF; if it produces no land description (expected, given no parseable legal), fall back to manual land-desc entry. Then re-export via ch-lease-exporter → IIF creates `tblleaseAbstractMapping` → mapping_id → producer → glue. Re-verify CSTitle land descriptions → DIV1 mapping_id → ES `legal_lease`.
