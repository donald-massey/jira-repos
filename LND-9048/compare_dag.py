"""Compare DAG source and variables between Prod (git repo) and Dev Airflow."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

# --- Configure these paths ---
PROD_DAGS_REPO = Path("C:/path/to/prod/dags/repo")  # root of the git-synced DAGs repo
COMPARE_DIR = Path(__file__).parent / "compare"       # where dev DAG files and var exports live
# -----------------------------


def load_variables(path: Path) -> dict:
    """Load variables JSON — handles both flat dict and list-of-records formats."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        # Airflow UI export: [{"key": ..., "val": ..., "description": ...}]
        return {item["key"]: item.get("val", item.get("value", "")) for item in raw}
    raise ValueError(f"Unrecognised variables format in {path}")


def compare_source(dag_name: str, prod_path: Path, dev_path: Path) -> bool:
    print(f"\n{'=' * 60}")
    print(f"DAG SOURCE DIFF: {dag_name}")
    print(f"  Prod: {prod_path}")
    print(f"  Dev:  {dev_path}")
    print(f"{'=' * 60}")
    result = subprocess.run(
        ["git", "diff", "--no-index", "--", str(prod_path), str(dev_path)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print("  No differences.")
        return True
    print(result.stdout)
    return False


def compare_variables(prod_path: Path, dev_path: Path) -> bool:
    print(f"\n{'=' * 60}")
    print("VARIABLES DIFF")
    print(f"  Prod: {prod_path}")
    print(f"  Dev:  {dev_path}")
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


def resolve_prod_dag(dag_name: str, prod_repo: Path) -> Path:
    """Find <dag_name>.py anywhere under the prod repo."""
    matches = list(prod_repo.rglob(f"{dag_name}.py"))
    if not matches:
        print(f"ERROR: {dag_name}.py not found under {prod_repo}", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"WARNING: multiple matches for {dag_name}.py — using first:", file=sys.stderr)
        for m in matches:
            print(f"  {m}", file=sys.stderr)
    return matches[0]


def main():
    parser = argparse.ArgumentParser(
        description="Compare DAG source and variables between Prod and Dev Airflow."
    )
    parser.add_argument("dag_name", help="DAG name, e.g. abstract_plant")
    parser.add_argument(
        "--prod-repo",
        default=str(PROD_DAGS_REPO),
        help="Path to the Prod DAGs git repo root",
    )
    parser.add_argument(
        "--compare-dir",
        default=str(COMPARE_DIR),
        help="Directory containing the Dev DAG file and variable exports",
    )
    parser.add_argument("--prod-vars", help="Path to Prod variables JSON (overrides default)")
    parser.add_argument("--dev-vars", help="Path to Dev variables JSON (overrides default)")
    parser.add_argument("--skip-source", action="store_true", help="Skip DAG source diff")
    parser.add_argument("--skip-vars", action="store_true", help="Skip variables diff")
    args = parser.parse_args()

    compare_dir = Path(args.compare_dir)
    compare_dir.mkdir(parents=True, exist_ok=True)

    clean = True

    if not args.skip_source:
        prod_dag = resolve_prod_dag(args.dag_name, Path(args.prod_repo))
        dev_dag = compare_dir / f"{args.dag_name}.py"
        if not dev_dag.exists():
            print(
                f"ERROR: Dev DAG file not found at {dev_dag}\n"
                f"Copy the source from the Dev Airflow Code tab and save it there.",
                file=sys.stderr,
            )
            sys.exit(1)
        clean &= compare_source(args.dag_name, prod_dag, dev_dag)

    if not args.skip_vars:
        prod_vars = Path(args.prod_vars) if args.prod_vars else compare_dir / "prod_variables.json"
        dev_vars = Path(args.dev_vars) if args.dev_vars else compare_dir / "dev_variables.json"
        for label, path, hint in [
            ("Prod", prod_vars, "airflow variables -e prod_variables.json  (Prod CLI)"),
            ("Dev", dev_vars, "airflow variables export dev_variables.json  (Dev CLI)  OR  Admin > Variables > Export"),
        ]:
            if not path.exists():
                print(f"ERROR: {label} variables not found at {path}", file=sys.stderr)
                print(f"  Export with: {hint}", file=sys.stderr)
                sys.exit(1)
        clean &= compare_variables(prod_vars, dev_vars)

    print(f"\n{'=' * 60}")
    print("RESULT:", "CLEAN — no differences found." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'=' * 60}\n")
    sys.exit(0 if clean else 1)


if __name__ == "__main__":
    main()
