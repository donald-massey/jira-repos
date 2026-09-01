# Context: DIML Loaders

Loaders that pull extraction datasets from the DIML platform and write them into
target schemas on the CS Digital database. This document defines the shared
vocabulary. Architectural decisions live in [`docs/adr/`](docs/adr/).

## Glossary

**DIML** — The upstream ingestion platform. Exposes an Elasticsearch dataset index
(what datasets exist and when they were created), result files in S3 (the actual
extracted content), and an API used to fetch those files.

**Loader** — A process that queries DIML for new datasets, parses them, and writes
the results into a target schema. Three loaders exist: `digital_clerk_diml_loader`,
`iie_diml_loader`, and `okcr_diml_loader`. Each run is a single invocation of one
loader.

**IIE** — Instrument Info Extraction. The ML-produced extraction results for land
instruments (abstracts, grantors/grantees, legal descriptions, lease clauses, etc.).
The IIE loader writes these into the `IIE` schema as extractions and their child
entities.

**Priority** *(IIE only)* — Datasets are tagged `high`, `medium`, or `low`
(`data.iie_priority`). `high` is the daily update stream; `medium` and `low` are
historical backfill. The IIE loader processes one priority per run, selected by the
`IIE_PRIORITY` environment variable.

**Dataset** — One unit of extraction results in DIML: Elasticsearch metadata plus a
result JSON file in S3. Identified by `dataset_id`. Datasets are ordered by their
`created_at` timestamp.

**Package** (`package_id`) — The identifier of the source document a dataset was
extracted from. Deduplication is by `package_id`: a package that already has an
extraction is skipped, which is what makes reprocessing an overlapping window safe.

**Extraction** (`InstrumentExtraction`) — One parsed instrument record written to the
`IIE` schema, with many child entities (abstracts, grantees, sections, clauses, …).

**loaderStatus** — The control table (`dbo.loaderStatus`, CS Digital database). One
row per loader — and per *priority* for IIE. Holds the run lock and the checkpoint.

**running** — Boolean lock on a `loaderStatus` row. `true` means a run owns that
loader. Prevents two runs of the same loader from overlapping.

**lastLoaded** — The checkpoint timestamp on a `loaderStatus` row: the watermark of
dataset `created_at` values that have been processed. A run queries datasets created
after `lastLoaded` (minus a fixed overlap) and, on success, advances it.

**priority_loader_id** — The `loaderStatus` row key. For IIE it is
`iie_diml_loader-{priority}` (e.g. `iie_diml_loader-medium`); for other loaders it is
just the loader name. IIE tracks a separate lock and checkpoint per priority.

**Window** — The `created_at` range a single run queries: from `lastLoaded` (minus a
fixed one-day overlap that absorbs Elasticsearch indexing lag) up to the run's end
bound.

**Batch** — A group of datasets processed together under one database session and
commit. The unit of memory pressure and, where checkpointing applies, the unit of
committed progress.

**Checkpoint** — Advancing `lastLoaded` to record that datasets up to a given
`created_at` have been durably written. The IIE loader checkpoints *mid-run*, every
tenth batch, to the maximum `created_at` of the **last fully-committed** batch (never
an in-flight one). Other loaders checkpoint only at end of run.

**Finalize** — The end-of-run advance of `lastLoaded` to the run's *end bound*
(`this_load_date`), covering any trailing span of the window that held no datasets. It
is **skipped when a run stops at the batch cap**, because the tail past the last
committed batch has not been processed and must not be checkpointed over.

**Batch cap** (`IIE_MAX_BATCHES`) — The maximum number of batches an IIE run processes
before stopping cleanly (set to `100` in dev+prod; at the Consul `IIE_BATCH_SIZE=100`, a
10,000-dataset ceiling per run). Bounds a single run's runtime and the cross-priority
lock it holds. Composes
with the checkpoint: a capped run leaves `lastLoaded` at its last committed batch, and
the next scheduled run resumes from there, draining the backlog in monotonic slices.
