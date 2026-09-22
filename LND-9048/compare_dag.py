"""Compare DAG source and variables between Prod and Dev Airflow.

Usage:
    python compare_dag.py <dag_folder>

Expected folder contents:
    prod.py              — DAG source from the Prod git repo
    dev.py               — DAG source copied from Dev Airflow Code tab
    prod_variables.json  — exported via: airflow variables -e prod_variables.json
    dev_variables.json   — exported via: airflow variables export dev_variables.json
                           OR Admin > Variables > Export in the Dev UI
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def load_variables(path: Path) -> dict:
    """Load variables JSON — handles flat dict and list-of-records formats."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        return {item["key"]: item.get("val", item.get("value", "")) for item in raw}
    raise ValueError(f"Unrecognised variables format in {path}")


def check_files(folder: Path, skip_source: bool, skip_vars: bool) -> None:
    required = []
    if not skip_source:
        required += ["prod.py", "dev.py"]
    if not skip_vars:
        required += ["prod_variables.json", "dev_variables.json"]

    missing = [f for f in required if not (folder / f).exists()]
    if missing:
        print(f"ERROR: missing files in {folder}:", file=sys.stderr)
        for f in missing:
            print(f"  {f}", file=sys.stderr)
        sys.exit(1)


def compare_source(folder: Path) -> bool:
    prod = folder / "prod.py"
    dev = folder / "dev.py"
    print(f"\n{'=' * 60}")
    print(f"DAG SOURCE DIFF  ({folder.name})")
    print(f"  prod: {prod}")
    print(f"  dev:  {dev}")
    print(f"{'=' * 60}")

    result = subprocess.run(
        ["git", "diff", "--no-index", "--", str(prod), str(dev)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print("  No differences.")
        return True
    print(result.stdout)
    return False


def compare_variables(folder: Path) -> bool:
    prod_path = folder / "prod_variables.json"
    dev_path = folder / "dev_variables.json"
    print(f"\n{'=' * 60}")
    print("VARIABLES DIFF")
    print(f"  prod: {prod_path}")
    print(f"  dev:  {dev_path}")
    print(f"{'=' * 60}")

    prod = load_variables(prod_path)
    dev = load_variables(dev_path)
    all_keys = sorted(set(prod) | set(dev))

    missing_in_dev = [k for k in all_keys if k in prod and k not in dev]
    only_in_dev = [k for k in all_keys if k not in prod and k in dev]
    changed = [k for k in all_keys if k in prod and k in dev and prod[k] != dev[k]]

    if missing_in_dev:
        print(f"\n  Missing in Dev ({len(missing_in_dev)}):")
        for k in missing_in_dev:
            print(f"    - {k} = {prod[k]!r}")

    if only_in_dev:
        print(f"\n  Only in Dev ({len(only_in_dev)}):")
        for k in only_in_dev:
            print(f"    + {k} = {dev[k]!r}")

    if changed:
        print(f"\n  Changed ({len(changed)}):")
        for k in changed:
            print(f"    ~ {k}")
            print(f"      Prod: {prod[k]!r}")
            print(f"      Dev:  {dev[k]!r}")

    if not any([missing_in_dev, only_in_dev, changed]):
        print("  No differences.")
        return True

    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", help="Path to the DAG comparison folder (e.g. abstract_plant/)")
    parser.add_argument("--skip-source", action="store_true", help="Skip DAG source diff")
    parser.add_argument("--skip-vars", action="store_true", help="Skip variables diff")
    args = parser.parse_args()

    folder = Path(args.folder)
    if not folder.is_dir():
        print(f"ERROR: {folder} is not a directory", file=sys.stderr)
        sys.exit(1)

    check_files(folder, args.skip_source, args.skip_vars)

    clean = True
    if not args.skip_source:
        clean &= compare_source(folder)
    if not args.skip_vars:
        clean &= compare_variables(folder)

    print(f"\n{'=' * 60}")
    print("RESULT:", "CLEAN — no differences found." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'=' * 60}\n")
    sys.exit(0 if clean else 1)


if __name__ == "__main__":
    main()
