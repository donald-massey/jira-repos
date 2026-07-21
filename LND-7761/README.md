# LND-7761 — Archive Deprecated Repositories in the Land Org

Tooling and review artifacts for auditing the **Land** GitHub org on
`git.drillinginfo.com` (GitHub Enterprise Server) and archiving repositories that are
deprecated with certainty, per [LND-7761](https://enverus.atlassian.net/browse/LND-7761).

The org has ~178 repos (≈119 active, ≈59 already archived). The 17 candidates flagged on the
ticket in Feb were already archived; the real work is reviewing the remaining **active** repos and
archiving the dead ones without breaking anything still scheduled.

## How it fits together

```
gh CLI (authed to git.drillinginfo.com)
        │
        ▼
main.py report ──► land_repos_report.csv        (raw facts: every repo, sorted by last activity)
        │
        ▼ (+ verdict heuristic + Nomad/clone/DAG signals)
   review artifacts:
     • review.md                 (human-readable checklist)
     • SharePoint workbook       (shared with team for parallel review — see link below)
        │
        ▼ (team marks KEEP)
   to_archive.txt                (final list — only uncommented names get archived)
        │
        ▼
main.py archive [--execute] ──► archives repos via gh, prints a Jira-ready list
```

## Prerequisites

- **`gh` CLI** authenticated to the enterprise host. Verify with:
  `gh auth status` (must show `git.drillinginfo.com` with the `repo` scope).
  All `gh` calls in `main.py` set `GH_HOST=git.drillinginfo.com`.
- **Python 3.11+** (stdlib only for `main.py`).
- **openpyxl** (`pip install openpyxl`) — only needed to regenerate the review workbook locally.

## `main.py`

Thin wrapper over `gh`. No tokens, no `.env` — it reuses your existing `gh` login.

### report — build the fact sheet

```
python main.py report [--output land_repos_report.csv] [--active-only] [--no-dags]
```

Writes a CSV of every org repo sorted by last activity (oldest first). Columns:
`name, archived, updated_at, pushed_at, created_at, language, open_issues, size_kb, has_dags,
description, html_url, tyler_candidate`.

- `has_dags` — repo has a top-level `dags/` dir (ships an Airflow DAG). Checked per-repo via the
  contents API; `--no-dags` skips it for speed.
- `tyler_candidate` — one of the 17 originally flagged on the ticket.
- `--active-only` — exclude already-archived repos.

### archive — apply the decisions

```
python main.py archive [--input to_archive.txt] [--execute]
```

Reads repo names (one per line; `#` comments ignored), and for each: re-checks state, **skips
already-archived**, and archives via `gh api -X PATCH repos/Land/<name> -F archived=true`.
Dry-run by default — prints what *would* happen and a Jira-ready bullet list. Add `--execute` to
apply. Archiving is reversible in GitHub (repo goes read-only; unarchive restores it).

## Review artifacts

Generated from `land_repos_report.csv` plus three live-use signals the raw API doesn't expose:

| Signal | Meaning |
|--------|---------|
| `DAG`       | repo ships an Airflow dag — **its DAG must be removed before archiving** |
| `nomad`     | a Nomad job template exists in `og-nomad-scheduler` (may still be deployed) |
| `clone`     | a local working copy exists under `~/PycharmProjects` (likely active) |
| `migr-push` | `pushed_at` is GitHub-migration noise — push year ≫ update year, so recency is fake |

### Verdicts

Each active repo gets one of four verdicts (recommendation only — the team decides):

- **ARCHIVE** — empty/test repos, or stale standalone repos (last *real* activity ≤ 2021, no DAG,
  no Nomad job, no local clone).
- **CHECK** — needs a human decision: ships a DAG, has a Nomad template, has a local clone, is a
  possible DLL dependency of the still-maintained `DID_*` data-entry suite, or is mid-age (2022–23).
- **KEEP?** — leans keep (real activity in 2024).
- **KEEP** — active (real activity ≥ 2025).

"Real activity" = `min(pushed_at, updated_at)` when those years diverge by ≥2 (defeats the
migration-push noise), otherwise `pushed_at`.

### Files

- **`review.md`** — full checklist of all active repos, grouped by verdict, with clickable links
  and a `keep` checkbox per repo. Note: checkboxes only toggle by click on GitHub web UI
  (issues/PRs); in PyCharm/VS Code edit the `[ ]` → `[x]` in source.
- **[SharePoint workbook](https://drillinginfo-my.sharepoint.com/:x:/r/personal/donald_massey_drillinginfo_com/Documents/LND-7761_review.xlsx?d=w06183b6c1a8f4030a02771e774614994&csf=1&web=1&e=CH8yLK)** — single shared workbook with a READ ME sheet and a Review sheet: highlighted `KEEP` column (KEEP-verdict rows pre-marked) and a `notes` column. All team members edit the same file.

## End-to-end workflow

1. `python main.py report` — regenerate `land_repos_report.csv`.
2. Regenerate `review.md` from it (verdict heuristic + signals above).
3. Team reviews the shared [SharePoint workbook](https://drillinginfo-my.sharepoint.com/:x:/r/personal/donald_massey_drillinginfo_com/Documents/LND-7761_review.xlsx?d=w06183b6c1a8f4030a02771e774614994&csf=1&web=1&e=CH8yLK); each member marks `KEEP` and adds notes.
4. Rebuild `to_archive.txt` from the workbook — a repo survives if **anyone** marks it keep
   (DID_* and DAG-bearing repos need extra sign-off / DAG removal first).
5. For any `has_dags` repo being archived: remove its Airflow DAG (and Airflow Variable / Nomad
   job) **first**, so the scheduler stops running dead code.
6. `python main.py archive` (dry-run) → confirm → `python main.py archive --execute`.
7. Post the archived list to LND-7761 so the action is tied back to the ticket.

## Caveats

- **Migration noise:** the GitHub Enterprise migration mass-re-pushed old repos, so `pushed_at`
  alone overstates activity. Trust the `migr-push` tag and the `updated_at` column.
- **`DID_*` suite:** the combined-form data-entry apps are still maintained and several old
  `DID_*` repos are "dll for combined form" — confirm with the app owner before archiving any.
- **Nomad templates persist** after a repo is archived (already-archived repos still have
  `.ctmpl` files), so a template's existence is a caution flag, not proof a repo is live.