**Issue 1 — Producer Crash (Shape 2: one recordID → many package_ids)**
- 4,500 records in `tblDimlXref` each have two rows pointing to two *different* package_ids, which causes `pd.merge` in land-lease-producer to explode instrument rows and crash the pipeline.
- Root cause: `TblDimlXRef.insert` in cs-digital-mfg has no existence check and no unique constraint on `recordID`, so a re-load appends a second row instead of replacing.
- A DIML content check (run 2026-06-30) confirmed all 2,830 live records (the actual crash population) point to byte-identical PDFs — so deduping is safe with no document resolution needed.
- A one-line `drop_duplicates` guard in the producer stops the crash immediately; the actual xref dedupe cleans the root cause.
- 1,670 additional orphaned xref rows exist (no matching `tblRecord`) — can't crash anything, cleanup only, pending team decision.

DM NOTE: Dedupe process is already built, want a sanity check before pulling the trigger.
DM NOTE: The land-lease-producer is processing counties completely per tblDataLoadersPerCounty



**Issue 2 — Data Correctness (Shape 1: one package_id → many recordIDs)**
- 2,192 package_ids are shared across records from different counties — same DIML document registered under multiple county identities due to an unstable county name from the scraper (tracked as LND-6879, now done).
- 668 package_ids are shared across records with *different* underlying PDFs — meaning COLE may have OCR'd the wrong document entirely.
- Union of both = 4,838 records that need COLE recompute via a fixed-dataset upload.
- Recompute is blocked on two dependencies: (a) county corrections must be made to `tblRecord` first (COLE trusts the supplied county, does not self-correct); (b) the 668 different-PDF records must be fixed at the DIML package→PDF binding level (`imageLocation` in the fixed dataset is not enough — COLE re-pulls from DIML by package_id).
- LND-6879 is confirmed deployed; remaining gate is the county + PDF binding fixes before uploading the reprocess CSV.

DM NOTE: Maybe we could rescrape these? I could ask Ty, I'm not sure how it could be handled without someone hand gathering the counties because they weren't correct at load time

**Issue 3 — Misassociated Images Published to Site**
- Investigation confirmed that incorrect images are actively being displayed on the site — the image shown for a record does not match the county the record belongs to.
- This is a downstream consequence of the cross-county package_id sharing in Issue 2: because DIML stores artifacts keyed by package_id (last-writer-wins), a record in the wrong county pulls the image that was last associated with that package_id, which may belong to a different county entirely.
- Correcting this requires reacquiring the images and re-associating them with the correct counties — not just a metadata fix.
- DM NOTE: Need to loop in Tyler Jordan to see if he has a plan or tooling we can leverage to handle the reacquisition. Unclear if this can be automated or requires manual county resolution at the source.
