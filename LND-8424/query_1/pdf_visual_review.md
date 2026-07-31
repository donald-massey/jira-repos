# Level 1 — PDF visual review (duplicate-vs-distinct + legal-parseability)

Runs **after** `compare_duplicate_records.sql` and `doc_image_paths.sql`. SQL fields
(dates, parties, image size) only *suggest* duplicate-vs-distinct; the images settle it.
This step also decides whether the document even *has* a parseable legal — which the
mapping_id / land-description chain depends on, and which no SQL query can tell you.

## Procedure

1. Run `doc_image_paths.sql` to get the on-prem UNC path for each RecordID
   (`storageFilePath + '\' + originalFileName`), e.g.
   `\\aus2-cs-fss01.na.drillinginfo.com\CS_TitleImages\CountyScansTitleImages\gpdm_imagestore\Merced_IMAGES\<recid-prefix>\<recordID>.pdf`.
2. Open/read both PDFs and compare side by side. Decide two things:
   - **Same instrument?** Same recorder stamp (doc#, recording date/time, barcode,
     fees, page count) + same parties + same body text = one instrument, two scans →
     duplicate. Different parties or different document = distinct filings.
   - **Parseable legal?** Does the body carry section/township/range, an abstract/survey,
     or metes-and-bounds? A street address + acreage is **not** a parseable legal — COLE
     has nothing to extract, so `tblLandDescription` stays empty even on a clean reprocess.
3. Record the verdict below. It drives remediation shape:
   - duplicate → remediate only the record that reached DIV1; the other needs no re-export.
   - no parseable legal → COLE reprocess won't populate descriptions → manual land-desc
     entry (or accept as a no-legal doc), not reprocess + re-export.

## Findings — reviewed 2026-07-31

Paths reviewed:
- `...\Merced_IMAGES\90c3\90c3e6e1-263c-4470-92c2-652f03092842.pdf` (884,986 bytes)
- `...\Merced_IMAGES\c5d1\c5d14542-c2ea-4a4a-8532-0936227ad2ec.pdf` (526,535 bytes)

**Same instrument — two scans, not distinct leases.** Both are Doc# **2024017111**,
recorded 07/22/2024 12:38 PM, Matt H. May / Merced County, same barcode
`*S100005986423*`, same recorder block (Titles 1 / Pages 4 / PAID 98.00). Same
Memorandum of Lease body: Tenant **Guru Ardaas Inc** (Prabhjot Singh, President),
Landlord **59 Petroleum LLC** (Inderjeet Singh, Manager), premises 3101 N. Hwy 59
Merced, ground lease dated 1-1-2023, signed 18 July 2024. 90c3 is a heavier scan
(more moiré → larger file); c5d1 is a lighter scan of the same page.

**The "58 vs 59 PETROLEUM LLC" is a metadata/keying error, not a real difference.**
Both images clearly read **59** Petroleum LLC. The grantee "58 PETROLEUM LLC" stored
against 90c3e6e1 in CSTitle is a data-entry/OCR error. This **overturns** the earlier
"likely DISTINCT leases" verdict → c5d14542 is a duplicate; remediating it would create
a duplicate lease.

**No parseable legal in the document.** It is a Memorandum of Lease whose only land
reference is a street address + acreage: "3101 N. Hwy 59 Merced, CA 95348, consisting
of approximately 1.38 acres." No section/township/range, no metes-and-bounds, no
abstract/survey. So the empty `tblLandDescription` is a **document-type limitation**
(COLUMBIA-like), not purely the COLE "No pdf available" error — a COLE reprocess of the
now-staged PDF will likely still yield nothing mappable.

**Verdict:** one instrument, no mappable legal. Remediation is manual land-description
entry (or accept as no-legal), **not** COLE reprocess + re-export. c5d14542 needs no
separate action.
