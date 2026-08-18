# LND-8655: Recent LA LegalLeases Not Published

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8655
**Status:** CANDIDATE FOR DEV

Max Lease Date search for some LA counties showed max lease dates behind our most recent published leases.

Attached you will find a list of affected records that fall within the following counties:

- Beauregard, LA = 9 records
- Plaquemines, LA = 27 records
- St. Bernard, LA = 1 record

## Approach

Standard two-level investigation per the LND-8426 runbook.

- **Level 1 (IIF/ch-lease-exporter):** All 37 records have non-null `Div1_LeaseID` and `exportLogID` — IIF is clean, skip to Level 2.
- **Level 2 (CSTitle tblLandDescription):** Check whether keyer-entered land description fields exist. Without populated section/township/range/BriefLegal, ch-lease-exporter produces no legal → DIV1 gets no abstract mapping → `mapping_id` IS NULL → Glue drops the record.

## Completed

**query_1** — run against `AUS2-PHX-DSQL01 / countyScansTitle` (2026-08-10):

- All 24 unique records have valid S3 images (confirmed via `tblS3Image`).
- `tblLandDescription` results across 24 records:
  - 13 records: zero rows (8 Beauregard + 5 Plaquemines)
  - 10 records: rows exist but all keyed fields NULL (section, township, rangeOrBlock, AbstractName, BriefLegal)
  - 1 record (`9676f3d8`, Beauregard): IsDeleted=1

**PDF + instrument type review** (22 of 24 PDFs read; `3bee5a55` and `915c8314` unread — 15 pages, pdftoppm unavailable):

**Beauregard (9 records) — all releases, all `recordIsLease=1`:**
- 7 CO2 storage lease releases (`008773a0`, `91d21121`, `9676f3d8`, `9c938807`, `a5a84d16`, `d740bc6f`, `e69aab8f`): no legal description in document. Not actionable — releases of subsurface CO2 storage rights, no S/T/R exists.
- 1 ROGL (`7f84be77`): legal description confirmed present in PDF (Exhibit A with S/T/R). **Keyer gap — actionable.**
- 1 OGM release (`ac257b8b`): references prior record only, no legal description in document.

**Plaquemines (14 records) — all active OGM leases, all `recordIsLease=1`:**
- Louisiana State Mineral Board offshore leases (Breton Sound Area, Gulf of Mexico). Legal descriptions are coordinate-based metes and bounds (X/Y coordinates in Louisiana Coordinate System of 1927) — no section/township/range exists. Pipeline cannot create abstract mapping regardless of keyer input.
- Multiple CSTitle records point to the same underlying court documents: 071ff440+1831f486 (SL 22079), 0f38fa5b+ccfa9f65 (SL 22080), 23072731+5b0b2846 (SL 22081), 4ca6bd12+c3db673d+d1cc62c9 (SL 22082), 67aede5a+8627418e (SL 22085).
- `3bee5a55` and `915c8314`: instrument type confirms same offshore lease pattern; PDF content unverified.

**St. Bernard (1 record) — OGL, `recordIsLease=1`:**
- State offshore lease (SL 21787). Coordinate-based metes and bounds, no S/T/R. Same limitation as Plaquemines.

**Root cause:**
- `7f84be77`: keyer gap — legal present in document, tblLandDescription never populated.
- All other 23 records: document-type limitation — CO2 releases have no legal description; offshore state leases use coordinate geometry incompatible with the S/T/R-based abstract mapping logic. These cannot be published via the standard pipeline without a structural change.

## Resolution — no actionable records

The earlier "`7f84be77` = keyer gap, rekey it" conclusion is **RETRACTED**. `7f84be77`
is a *release* of an OGL, which conveys no leasehold. query_3 (2026-08-14) confirms:

- 373/373 records of instrument type "RELEASE OF OIL GAS AND MINERAL LEASES" are
  `recordIsLease=0` — releases are consistently and correctly flagged not-a-lease.
- `7f84be77` was already corrected since query_1 (2026-08-10): now `recordIsLease=0`
  (was 1) and `statusID=17` = **"Filtered Non Lease Type"** (was 4/Published). Reworked
  2026-08-13 by data entry (keyer 950); supervisor comment "(DG 8/13/26) Please review
  legals and correct or add as needed. Resubmit." It is deliberately filtered out of the
  legal_lease pipeline as a release and no longer belongs there.

So the record was NOT a missing land description — the original data error was that a
release had been tagged as a lease, and that has been fixed. Rekeying would have been
wrong (manufacturing a land description to force a release into `legal_lease`).

All 24 records now accounted for, none actionable via the standard pipeline:
- `7f84be77` — reclassified as a release (recordIsLease=0, statusID 17).
- 8 other Beauregard — CO2-storage / OGM releases, no legal description in document.
- 14 Plaquemines + 1 St. Bernard — offshore state leases, coordinate geometry, no S/T/R.

**query_2** (pipeline verification) is superseded/moot — kept for reference only.
**query_3** — `release_ogl_notlease_count.sql` (373 releases, all recordIsLease=0) and
`record_7f84be77_flag_check.sql` (live-row reconciliation; statusID 17 = "Filtered Non
Lease Type").
