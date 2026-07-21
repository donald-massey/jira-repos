"""LND-7761: report on and archive deprecated repositories in the Land GitHub org.

Wraps the already-authenticated `gh` CLI against git.drillinginfo.com (GitHub
Enterprise). Two modes:
    report  - write a CSV of org repos sorted by last activity (oldest first)
    archive - archive a confirmed list of repos (dry-run unless --execute)
"""

import argparse
import csv
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

GH_HOST = "git.drillinginfo.com"
ORG = "Land"

# Tyler Jordan's 17 originally-identified candidates (all already archived as of
# this effort; kept for traceability in the report).
TYLER_CANDIDATES = {
    "EOGQuarterlyExporter", "CourthouseBrokenCounties", "ReaganReplace",
    "tesseract_testing", "export_county_images_database", "DID_JPEGDNAS",
    "instrument-backloader", "CSHistorical_Loader", "CSDIGITAL_IMAGE_UPDATER",
    "DocumentRebuilder", "OCR_IMAGE_CLASSIFICATION",
    "eog_halfile_to_cstitle_conversion_scripts", "CountyUpdates",
    "diml-resolve-multi-file-dataset-bug", "DirectionalSurveys",
    "BatchRepairs", "CH-Data-Repair-Scripts",
}

CSV_COLUMNS = [
    "name", "archived", "updated_at", "pushed_at", "created_at", "language",
    "open_issues", "size_kb", "has_dags", "description", "html_url",
    "tyler_candidate",
]


def gh(api_args, check=True):
    """Run a gh command against the enterprise host and return the CompletedProcess."""
    env = {**os.environ, "GH_HOST": GH_HOST}
    return subprocess.run(
        ["gh", *api_args], env=env, capture_output=True, text=True, check=check
    )


def list_repos():
    """Return all repos in the org as parsed JSON, sorted oldest-pushed first."""
    result = gh([
        "api", f"orgs/{ORG}/repos?per_page=100&sort=pushed&direction=asc",
        "--paginate",
    ])
    return json.loads(result.stdout)


def has_dags(name):
    """True if the repo contains a top-level dags/ directory (ships an Airflow DAG)."""
    result = gh(["api", f"repos/{ORG}/{name}/contents/dags"], check=False)
    return result.returncode == 0


def get_repo(name):
    """Return the repo's JSON, or None if it does not exist / is inaccessible."""
    result = gh(["api", f"repos/{ORG}/{name}"], check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def archive_repo(name):
    gh(["api", "-X", "PATCH", f"repos/{ORG}/{name}", "-F", "archived=true"])


def cmd_report(args):
    repos = list_repos()
    if args.active_only:
        repos = [r for r in repos if not r["archived"]]

    dag_flags = {}
    if not args.no_dags:
        names = [r["name"] for r in repos]
        with ThreadPoolExecutor(max_workers=8) as pool:
            dag_flags = dict(zip(names, pool.map(has_dags, names)))

    repos.sort(key=lambda r: r["pushed_at"] or "")

    with open(args.output, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(CSV_COLUMNS)
        for r in repos:
            writer.writerow([
                r["name"],
                r["archived"],
                r["updated_at"],
                r["pushed_at"],
                r["created_at"],
                r.get("language") or "",
                r.get("open_issues_count", ""),
                r.get("size", ""),
                dag_flags.get(r["name"], ""),
                (r.get("description") or "").replace("\n", " ").strip(),
                r["html_url"],
                r["name"] in TYLER_CANDIDATES,
            ])

    active = sum(1 for r in repos if not r["archived"])
    archived = len(repos) - active
    print(f"Wrote {len(repos)} repos to {args.output} ({active} active, {archived} archived).")
    if dag_flags:
        with_dags = sum(1 for r in repos if not r["archived"] and dag_flags.get(r["name"]))
        print(f"Active repos shipping a dags/ dir: {with_dags}")


def read_names(path):
    """Read repo names from a file, one per line, skipping blanks and # comments."""
    names = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                names.append(line)
    return names


def cmd_archive(args):
    names = read_names(args.input)
    if not names:
        print(f"No repo names found in {args.input}.")
        return

    archived_now = []
    for name in names:
        repo = get_repo(name)
        if repo is None:
            print(f"  NOT FOUND : {name}")
            continue
        if repo["archived"]:
            print(f"  skip      : {name} (already archived)")
            continue
        if args.execute:
            archive_repo(name)
            print(f"  ARCHIVED  : {name}")
        else:
            print(f"  [dry-run] : would archive {name}")
        archived_now.append((name, repo["html_url"]))

    print()
    if not archived_now:
        print("Nothing to archive.")
        return

    header = "Archived" if args.execute else "Would archive (dry-run)"
    print(f"{header} {len(archived_now)} repo(s) -- Jira list:")
    for name, url in archived_now:
        print(f"* [{name}]({url})")
    if not args.execute:
        print("\nRe-run with --execute to apply.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)

    p_report = sub.add_parser("report", help="write a CSV of org repos by last activity")
    p_report.add_argument("--output", default="land_repos_report.csv")
    p_report.add_argument("--active-only", action="store_true",
                          help="exclude already-archived repos")
    p_report.add_argument("--no-dags", action="store_true",
                          help="skip the per-repo dags/ check (faster)")
    p_report.set_defaults(func=cmd_report)

    p_archive = sub.add_parser("archive", help="archive a confirmed list of repos")
    p_archive.add_argument("--input", default="to_archive.txt")
    p_archive.add_argument("--execute", action="store_true",
                           help="actually archive (default is dry-run)")
    p_archive.set_defaults(func=cmd_archive)

    args = parser.parse_args()
    try:
        args.func(args)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"gh command failed: {exc.stderr or exc}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
