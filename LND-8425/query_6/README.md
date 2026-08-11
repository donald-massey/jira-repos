# LND-8425 — COLE fixed-dataset run (DIAGNOSTIC ONLY — not the lease fix)

**This does NOT fix the lease.** COLE never writes `countyScansTitle.dbo.tbllandDescription`
— its only DB output is `CS_Digital.cole.tblRecordProcessingLogs` (package_id, errorMessage,
OCRs3Path), and its extracted legals go to S3 → the CHD courthouse ES plants, a separate
product from Legal Leases. The lease's land descriptions are entered by title analysts
**manually abstracting** the lease; that is the real remediation (see CLAUDE.md).

Use this run only as a diagnostic: does COLE *can* OCR a legal off these 3 images at all
(output on S3 / OCRs3Path)? Useful to know if the images are readable, but a clean COLE run
will NOT populate `tbllandDescription` and will NOT unblock publish.

Repo: `land.courthouse-ocr-legals-extractor` (flow `COLE_fixed_dataset`).

## 1. Build the input CSV

Run `LND-8425-cole-fixed-dataset-input.sql` on the CSTitle server, export as CSV.
Name the file `{county}-{state}_{YYYYMMDDThhmmss}Z.csv` (UTC), e.g.
`miami-ks_20260810T145410Z.csv` — matches the COLE convention (`cibola-nm_20260728T153355Z.csv`).
Required columns (exact casing):

```
recordID,countyName,stateAbbreviation,imageLocation
```

- `imageLocation` MUST be the full **S3 URL** of the PDF (`s3://bucket/key`) — COLE
  url-parses it (`single_chunk_ocr_processor._download_pdf` →
  `get_bucket_and_prefix_from_full_location`). Use `tblS3Image.s3FilePath`; if it
  has no `s3://` scheme, prefix it. The on-prem `storageFilePath` UNC (query_5) will
  NOT work here.
- Null/empty `imageLocation` ⇒ OCR is skipped and IIE will not run for that row.
- If `s3FilePath` is NULL the image was never staged to S3 — a separate imaging gap;
  COLE can't OCR it until staged.

## 2. Upload to the COLE input prefix

FixedDatasetSelector reads CSVs from `hardcoded_input/` under the flow's storage base
`s3://land-{env}/data/courthouse-ocr-legals-extractor`, with the input-dataset segment:

```
s3://land-<env>/data/courthouse-ocr-legals-extractor/fixed_dataset/hardcoded_input/
```

Validate in **dev** first (`land-dev`) before prod (`land-prod`). Refresh AWS session
creds before the upload/run. Only `.csv` files are accepted; anything else, or a file
missing a required column, is moved to `_REJECTS/` with a `.error.txt` sidecar.

## 3. Run the flow with FORCE_RECOMPUTATION

The 2025 record already has a COLE log row that errored (`No pdf could be
downloaded…`, 2025-09-14). The default `COMPUTE_WHERE_NOT_COMPUTED_YET` would treat it
as already computed and skip it, so force it:

```
ocr_computation_type = FORCE_RECOMPUTATION
iie_computation_type = FORCE_RECOMPUTATION
```

Trigger the `COLE_fixed_dataset` Prefect deployment (or the k8s `cole-fixed-dataset`
job) with those two parameters. On success the input CSV is archived to
`hardcoded_input/_PROCESSED/`; rows with nulls are logged to
`hardcoded_input/_ERRORS/`.

## 4. Read the diagnostic result (does NOT gate the lease fix)

- CS_Digital `cole.tblRecordProcessingLogs` (query_4): did OCR/IIE run clean this
  time, or is `OCRErrorMessage` still set? COLE keys off `package_id`
  (`CS_Digital.dbo.tblDimlXref` → recordID).
- The extracted legal (if any) is on S3 at `OCRs3Path` — NOT in `tbllandDescription`.
  Checking `countyScansTitle.dbo.tbllandDescription` (query_2) after this run is
  pointless: COLE does not write there, so it will still be empty.

Interpretation:
- **COLE OCR'd a legal (S3 output present)** → the image is readable; a title analyst
  can abstract it quickly. Still requires manual abstracting to reach the lease.
- **COLE still errors / no legal** → images may be problematic; note it for the analyst.

Either way the lease fix is the same: **manual abstracting** (CLAUDE.md Remediation).
COLE reprocess never populates the lease's land descriptions.
