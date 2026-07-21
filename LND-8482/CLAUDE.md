# LND-8482 — Repair tblS3Image Records with Missing/Zero Metadata

Sub-task of LND-8093. Repairs `countyScansTitle.dbo.tblS3Image` rows the LND-8093
backfill left with `pageCount IS NULL` or `fileSizeBytes = 0`. Those rows were already
removed from S3 and the DB by `cleanup_null_metadata.py --commit`; this task
re-creates them correctly from the source file on the network share.

## Repo layout

Everything runs from **this** repo (`LND-8482`). Ported from `LND-8093`:

- `maintenance/repair_from_report.py` — rewritten here (the LND-8093 version does not
  convert TIFs or recover PDFs; it is the scaffolding, not the finished logic)
- `utils/` — `database_utils.py` (`connect_countyscanstitle`, `execute_query`,
  `execute_update`, transaction helpers), `s3_utils.py` (`S3Client`: `upload_bytes`,
  `upload_file`, `head_object`, `delete_objects`)
- `artifacts/cleanup_report_commit_*.csv` — the input report(s)
- `.env` / `requirements.txt` — add `pikepdf`, `Pillow`, `pypdf`

This CLAUDE.md is the design record and stays here.

## Input

`cleanup_report_*.csv` columns: `recordID, s3FilePath, pageCount, fileSizeBytes,
s3_existed`. **No `statusID`, no `fileExtension`** — both come from a `tblrecord` join
at repair time. Source file on the share is `{storageFilePath}\{recordID}{fileExtension}`.

## Design decisions (grilled 2026-07-17)

1. **Scope gate — keep `statusID IN (4,10)`.** Applied in the `tblrecord` lookup (add
   `statusID` to the SELECT), evaluated per record before any work. Out-of-scope rows
   are `skipped` (`reason='statusID not in (4,10)'`) — those records aren't published,
   so repairing them is wasted risk. A missing `tblrecord` row is `failed`
   (`recordID not found in tblrecord`), not skipped — can't confirm scope, don't drop.

2. **Route on magic bytes, not the extension.** The whole defect is bad metadata, so
   don't trust `fileExtension`. Sniff the header: `%PDF` → PDF path; `II*\0` / `MM\0*`
   → TIF path; anything else → `failed` (`reason='unknown file signature'`). Fall back
   to the extension only if the sniff is inconclusive.

3. **TIF → PDF via Pillow, then validate.** Enumerate frames (`seek`/`n_frames`,
   multi-page TIFs are common), `save(format='PDF', save_all=True)` to an in-memory
   buffer. Then re-open the produced PDF bytes with pypdf/pikepdf to confirm it's
   readable and take `pageCount` **from the PDF reader**, not the TIF frame count.
   Validation failure → `failed` (`reason='converted PDF failed validation'`).

4. **PDF repair — single-pass pikepdf, never loop.** Try `pypdf` open + page count. If
   it opens cleanly → the PDF was fine, just needed metadata (see repaired sub-cases).
   If it fails → one attempt at `pikepdf.open(..., recovery=True)`, save, re-validate
   with pypdf. Still bad → `failed`. Exactly one recovery attempt per file — the cap is
   structural, satisfying "don't endlessly retry."

5. **Network share write-back (new file next to original; never destroy the source):**
   - **TIF** → keep `{recordID}.tif`, write converted `{recordID}.pdf` alongside.
   - **Recovered PDF** → rename corrupt `{recordID}.pdf` → `{recordID}.old.pdf`, then
     write recovered bytes as a clean `{recordID}.pdf`. Keeps `fileExtension` a real
     `.pdf` (no column pollution) and preserves the original.
   - **PDF already valid** → no share change at all; just S3 + DB metadata.
   - Crash-safe order: write new bytes to a temp name → rename original to `.old.pdf`
     → move temp into `{recordID}.pdf`. Roll the rename back on failure so `tblrecord`
     never points at a missing file.

6. **`tblrecord` update.** Required or the share write is pointless (the path is
   rebuilt from `fileExtension`). TIF case → set `fileExtension` `.tif`→`.pdf`.
   Recovered/valid PDF case → `fileExtension` unchanged (already `.pdf`).

7. **S3 — fresh upload, clean key.** Post-cleanup there is no existing S3 object, so
   every repair is a new PUT. Key uses the real (post-conversion) name: TIF → `.pdf`
   key; PDF → `.pdf` key. Whatever key we upload becomes `tblS3Image.s3FilePath`
   verbatim — S3 and the DB must always agree. The `.old.pdf` forensic copy lives only
   on the share, never in S3.

8. **Write order: share → S3 → DB. DB is always last.** Nothing references the share
   file or S3 object until the DB row is written, so a failure in step 1 or 2 needs no
   revert — a re-run redoes it cleanly. Share/S3 order between themselves doesn't
   matter.

9. **DB write is one transaction:** upsert `tblS3Image` (new `.pdf` key, `pageCount`,
   `fileSizeBytes`, `_ModifiedBy='LND-8093-repair'`, UPDATE-else-INSERT since cleanup
   may have deleted the row) **and** the `tblrecord.fileExtension` update (TIF case)
   together. Match exact column casing from the schema.

10. **Idempotent + dry-run.** Every step is safe to re-run (overwrite same S3 key,
    upsert, `.old.pdf` rename is a no-op if already done). Gated by the existing
    `--commit` flag; dry-run logs intended actions and writes `would_repair`. Refresh
    `AWS_*` creds before any S3 work (they're short-lived).

## Repair report (`repair_report_{dryrun|commit}_{timestamp}.csv`)

| status | meaning |
|--------|---------|
| `repaired` | TIF converted / PDF recovered / PDF already valid — uploaded + DB updated |
| `skipped`  | `statusID NOT IN (4,10)` |
| `failed`   | recordID not in tblrecord, file missing, zero bytes, unknown signature, TIF conversion error, converted-PDF validation failure, pikepdf recovery exhausted, or S3 error |

`repaired` sub-cases (record the specific one in the reason/notes for audit): TIF
converted; corrupt PDF recovered via pikepdf; PDF opened clean and only needed metadata.

## External systems

- **countyScansTitle DB** (SQL Server) — `tblS3Image` (target), `tblrecord` (source of
  `storageFilePath`, `fileExtension`, `statusID`; also updated)
- **Network share** — source files at `{storageFilePath}\{recordID}{fileExtension}`;
  written back per decision 5
- **S3** `enverus-courthouse-prod-chd-plants` — converted/recovered PDFs uploaded here

## Done when

No `status='failed'` rows remain for `statusID IN (4,10)` records whose source file
exists on disk. Repaired `tblS3Image` rows have a `.pdf` `s3FilePath`, non-null
`pageCount`, and non-zero `fileSizeBytes`, and the corresponding share file + S3 object
both exist.
