"""Fetch all datasets from a DIML package by package_id.

Lists every dataset in the package, prints metadata, and optionally downloads
each file to a local directory named after the package_id.

Usage (PowerShell):
  .\.venv\Scripts\python.exe diml_fetch_package.py <package_id>
  .\.venv\Scripts\python.exe diml_fetch_package.py <package_id> --download
  .\.venv\Scripts\python.exe diml_fetch_package.py <package_id> --download --out-dir ./downloads

Requires the `diml_api_helper` package (install via requirements.txt) and
DIML/OAM network access (VPN must be up). DIML_OAMUSERNAME env var is read
for auth (default: diml-svc).
"""
import argparse
import os
import sys
import urllib.request
from pathlib import Path

from diml_api_helper import api

DIML_HOST = "app-a-in.drillinginfo.com/diml-core"


def build_client():
    return api.DimlApi(
        host=DIML_HOST,
        oamusername=os.environ.get("DIML_OAMUSERNAME", "diml-svc"),
    )


def fetch_datasets(diml, package_id):
    return diml.list_datasets(package_id=package_id)


def _filename_from_url(url, fallback):
    """Extract the filename from the URL path, stripping the presigned query string."""
    base = url.split("?")[0]
    name = base.rstrip("/").rsplit("/", 1)[-1]
    return name if name else fallback


def download_dataset(dataset, dest_dir, timeout=180):
    """Download a single dataset to dest_dir. Returns the local file path."""
    url = dataset.get("download_url")
    if not url:
        return None
    dataset_id = dataset.get("id") or dataset.get("dataset_id") or "unknown"
    filename = _filename_from_url(url, f"{dataset_id}.bin")
    out_path = dest_dir / filename
    if out_path.exists():
        out_path = dest_dir / f"{dataset_id}_{filename}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        out_path.write_bytes(resp.read())
    return out_path


def print_dataset_row(i, d):
    dataset_id = d.get("id") or d.get("dataset_id") or ""
    classification = d.get("classification") or ""
    dtype = d.get("type") or ""
    filename = d.get("file_name") or d.get("filename") or ""
    updated = d.get("updated_at") or ""
    print(f"  [{i:>3}] {dataset_id:<36}  {classification:<30}  {dtype:<10}  {filename:<40}  {updated}")


def main():
    parser = argparse.ArgumentParser(description="Fetch a DIML package by package_id")
    parser.add_argument("package_id", help="DIML package_id to fetch")
    parser.add_argument("--download", action="store_true", help="download all dataset files locally")
    parser.add_argument("--out-dir", default=None,
                        help="directory to write files into (default: ./<package_id>)")
    args = parser.parse_args()

    diml = build_client()
    print(f"DIML host : {DIML_HOST}  [PROD]")
    print(f"package_id: {args.package_id}")
    print()

    datasets = fetch_datasets(diml, args.package_id)
    if not datasets:
        print("No datasets found for this package_id.")
        sys.exit(0)

    print(f"Found {len(datasets)} dataset(s):\n")
    header = f"  {'#':>5}  {'dataset_id':<36}  {'classification':<30}  {'type':<10}  {'filename':<40}  updated_at"
    print(header)
    print("  " + "-" * (len(header) - 2))
    for i, d in enumerate(datasets, 1):
        print_dataset_row(i, d)

    if not args.download:
        print("\n(pass --download to fetch all files locally)")
        return

    dest_dir = Path(args.out_dir) if args.out_dir else Path(args.package_id)
    dest_dir.mkdir(parents=True, exist_ok=True)
    print(f"\nDownloading to: {dest_dir.resolve()}")
    for i, d in enumerate(datasets, 1):
        dataset_id = d.get("id") or d.get("dataset_id") or f"dataset_{i}"
        url = d.get("download_url") or ""
        filename = _filename_from_url(url, dataset_id) if url else dataset_id
        try:
            out_path = download_dataset(d, dest_dir)
            if out_path:
                print(f"  [{i:>3}] {filename} -> {out_path.name}")
            else:
                print(f"  [{i:>3}] {filename} -> (no download_url, skipped)")
        except Exception as e:
            print(f"  [{i:>3}] {filename} -> ERROR: {e}")

    print("\nDone.")


if __name__ == "__main__":
    main()
