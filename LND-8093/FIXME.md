# FIXME — LND-8093 code review

Review of the backfill pipeline. Structure is solid (clean module separation, idempotent inserts, real resumability). The items below are what bites at 9M-file scale and on the finalize error path — not architecture.

Nothing here blocks the **SD** validation pass (single-pass, small, error path won't trigger). The items that mattered before pointing this at TX's 6.2M — **#1–#3** (High) and **#4–#7** (Medium) — are all done; only the Low / notes below remain.

---

## High — fix before the TX run

- [x] **1. PDFs are read off the share twice, not once.** `process_utils.py` called `_get_pdf_page_count()` (opens via `PdfReader`) and then `upload_file()` (boto3 opens again) — two opens/reads per file over `\\aus2-cs-fss01` SMB. The "each file is touched once" docs claim was wrong.
  - **Done:** a PDF at or below `MAX_BUFFER_BYTES` (env `MAX_BUFFER_MB`, default 100) and not in verify mode is now read once into memory via `open().read()`; page count comes from `_pdf_page_count_from_bytes()` and the upload from new `S3Client.upload_bytes()` (single PUT) — same buffer, one share read. Larger files and verify mode keep the streaming path (separate page-count read + `upload_file`/`upload_and_verify`) to bound worker memory. Docs corrected in CLAUDE.md, `.env.example`, and the module docstring.

- [x] **2. finalize archives CSVs even when inserts failed.** `finalize_from_csv.py:125-131` — `archive_csv()` ran unconditionally after `finalize_csv()`, and `main()` only globs `migration_results/s3_backfill_batch_*.csv` (not `processed_archive/`). Any chunk that hit `errors` was moved out of the finalize pipeline and never retried by finalize.
  - **Done:** `finalize_from_csv.py` now archives only when `err == 0`; a CSV with any failed inserts is left in place and a warning is logged, so a re-run retries it (inserts are idempotent).

- [x] **3. One chunk per worker, no per-task timeout.** `main.py` — `chunk_list` split into exactly `MAX_WORKERS` contiguous chunks and `pool.map` handed one to each worker (no load balancing, no timeout; a hung SMB read could stall a whole ~62k-row chunk indefinitely).
  - **Done:** replaced with `chunk_by_size()` (fixed `CHUNK_SIZE`, default 2000) + `pool.schedule()` per chunk with a `BATCH_TIMEOUT` (default 1800s). All chunks are scheduled up front so workers pull the next as they free up; a timed-out chunk is killed and its unflushed rows retry next run. Both tunables are env-overridable and documented in `.env.example`.

---

## Medium

- [x] **4. The "inserted" count is optimistic.** `finalize_from_csv.py:91` — `inserted += len(params)` counts rows *submitted*, not rows that passed the `NOT EXISTS` guard (and `fast_executemany` rowcount is unreliable). On any re-run where rows already exist, the log overcounts.
  - **Done:** the per-CSV counter is relabeled `submitted` (honest about the `NOT EXISTS` guard), and `main()` now brackets the run with `_table_count()` (`SELECT COUNT(*) FROM tblS3Image`) and logs `before/after/(actually inserted=delta)` as the authoritative number. README's "row count rises by the copied count" still only holds on a clean first finalize — the delta line makes the real figure visible on every run.

- [x] **5. Parent holds every result dict + pickles them back over IPC.** `main.py:180/188`, `process_utils.py:124` — workers return the full `batch_results` list and the parent `results.extend()`s all of it just to print three counts. At a 500k TX window that's 500k dicts pickled across the process boundary and held in the parent on top of `work` and the `already` set.
  - **Done:** `process_batch` no longer builds a `batch_results` list — it increments running `counts` as it writes each CSV row and returns a fixed-size summary dict `{batch_number, copied, file_not_found, error, processed, csv_path}`. The parent reads those keys; the CSVs remain the source of truth, so nothing per-record crosses the process boundary or stays resident in the parent.

- [x] **6. Resume scan grows unbounded and is mostly redundant.** `main.py:116-137` — `load_already_processed_ids` reads **every** CSV in `migration_results/` *and* `processed_archive/`, across all states, into one set on every run. After many TX windows that's millions of GUIDs re-read each pass. Once finalized, `load_work`'s `NOT EXISTS` against `tblS3Image` already excludes those rows, so the CSV filter only meaningfully covers the not-yet-finalized in-flight batch.
  - **Done:** CSV filenames now carry the state (`s3_backfill_batch_{STATE}_{N}_{date}.csv` in `process_utils`) — which also fixes a latent same-day cross-state collision — and the resume glob is scoped to `s3_backfill_batch_{STATE}_*.csv`. The archive directory now contributes only `file_not_found` (its `copied` rows are already excluded by `load_work`'s `NOT EXISTS`, so re-reading them was pure waste); `migration_results/` still contributes both statuses since its `copied` rows aren't finalized yet. Within a single huge state across many windows the archive still accumulates `file_not_found` lines — prune the archive between windows if that ever matters.

- [x] **7. NULL/empty `fileExtension` mismatch.** Staging builds `s3FilePath` as `... + tr.recordID + tr.fileExtension` in SQL — if `fileExtension` is NULL the whole expression is NULL, and `tblS3Image.s3FilePath` is `NOT NULL`, so finalize would reject it. Meanwhile `process_utils._local_path` defaults to `.pdf` when ext is falsy — so Python and SQL disagree on those rows.
  - **Done:** `build_staging_table` resolves the extension once via `ext_expr = COALESCE(NULLIF(tr.fileExtension, ''), '.pdf')` and uses it for both the stored `fileExtension` column and the `s3FilePath` concatenation — matching `process_utils._local_path`'s `.pdf` default, so SQL and Python agree and `s3FilePath` can't go NULL. The COALESCE is defensive (no-op when the column is already populated); a record whose extension is genuinely NULL but whose file isn't a `.pdf` will surface as `file_not_found` on both sides consistently and be handed off.

---

## Low / notes

- [x] **Page-count failures still mark `copied`.** `process_utils.py:42-44`, `95` — a corrupt PDF uploads with `pageCount=NULL`. Schema allows it, but `copied` then doesn't guarantee a usable page count. Document for handoff.
  - **Done (documented):** behavior kept (the upload genuinely succeeded; only the page count failed). CLAUDE.md "Handoff notes" now documents it and gives the query to find them — `pageCount IS NULL AND s3FilePath LIKE '%.pdf'` (PDFs whose count couldn't be read, distinct from non-PDFs which are legitimately NULL).
- [x] **SQL injection via `STATE`.** `main.py:70` — env-controlled and `.upper()`'d, so low risk, but it's string-interpolated into the `SELECT INTO`. Parameterize or whitelist if you care.
  - **Done:** `main.py` now whitelists `STATE` at load (`ALL` or `^[A-Z]{2}$`, else `ValueError`) — covers both the interpolated staging-table name and the state filter.
- [x] **Deadlock-retry reconnect drops transaction state.** `database_utils.py:118-130` — safe *only* because no multi-statement transaction currently spans a retry; fragile if that changes.
  - **Done:** both `execute_many` and `execute_update` now re-raise a deadlock immediately when `self._in_transaction` (so the caller rolls back and retries the whole unit atomically); the reconnect+retry path is kept only for autocommit-style single statements.
- [x] **PyPDF2 is EOL** (renamed to `pypdf`) and `requirements.txt` is unpinned. Fine for a one-off, but pin versions so a fresh `pip install` reproduces later.
  - **Done:** `requirements.txt` pinned to the installed versions (`boto3/botocore==1.43.14`, `pypdf==6.12.1`, `python-dotenv==1.2.1`, `Pebble==5.1.1`, `pyodbc==5.2.0`); the worker imports `pypdf` with a `PyPDF2` fallback (confirmed resolving to `pypdf._reader`).
- [x] **Cosmetic:** `from __future__` before the docstring means these modules have no `__doc__`; `cursor.commit()` (`database_utils.py:149`) vs `self._conn.commit()` (`:113`) is inconsistent; `datetime.utcnow()` (`finalize_from_csv.py:107`) is deprecated in 3.12.
  - **Done:** docstring now precedes `from __future__` in all five modules (verified `__doc__` is set); `execute_update` uses `self._conn.commit()`; `finalize_from_csv` uses `datetime.now(timezone.utc)`.
