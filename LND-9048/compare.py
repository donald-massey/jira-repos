"""DAG comparison — fill in the variables below, then run: python compare.py

Place prod.py and dev.py in the same folder as this file before running.
"""

from pathlib import Path
import subprocess
import sys

# fmt: off
PROD_VARIABLES = {
    # "key": "value",
}

DEV_VARIABLES = {
    # "key": "value",
}
# fmt: on

# ---------------------------------------------------------------------------

HERE = Path(__file__).parent


def compare_source() -> bool:
    prod, dev = HERE / "prod.py", HERE / "dev.py"
    for label, path in [("prod.py", prod), ("dev.py", dev)]:
        if not path.exists():
            sys.exit(f"ERROR: {label} not found at {path}")

    print(f"\n{'='*60}\nDAG SOURCE DIFF\n{'='*60}")
    result = subprocess.run(
        ["git", "diff", "--no-index", "--", str(prod), str(dev)],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        print("  No differences.")
        return True
    print(result.stdout)
    return False


def compare_variables() -> bool:
    print(f"\n{'='*60}\nVARIABLES DIFF\n{'='*60}")
    all_keys = sorted(set(PROD_VARIABLES) | set(DEV_VARIABLES))

    missing_in_dev = [k for k in all_keys if k in PROD_VARIABLES and k not in DEV_VARIABLES]
    only_in_dev    = [k for k in all_keys if k not in PROD_VARIABLES and k in DEV_VARIABLES]
    changed        = [k for k in all_keys if k in PROD_VARIABLES and k in DEV_VARIABLES
                      and PROD_VARIABLES[k] != DEV_VARIABLES[k]]

    if missing_in_dev:
        print(f"\n  Missing in Dev ({len(missing_in_dev)}):")
        for k in missing_in_dev:
            print(f"    - {k} = {PROD_VARIABLES[k]!r}")
    if only_in_dev:
        print(f"\n  Only in Dev ({len(only_in_dev)}):")
        for k in only_in_dev:
            print(f"    + {k} = {DEV_VARIABLES[k]!r}")
    if changed:
        print(f"\n  Changed ({len(changed)}):")
        for k in changed:
            print(f"    ~ {k}")
            print(f"      Prod: {PROD_VARIABLES[k]!r}")
            print(f"      Dev:  {DEV_VARIABLES[k]!r}")
    if not any([missing_in_dev, only_in_dev, changed]):
        print("  No differences.")
        return True
    return False


if __name__ == "__main__":
    source_clean = compare_source()
    vars_clean = compare_variables()
    clean = source_clean and vars_clean
    print(f"\n{'='*60}")
    print("RESULT:", "CLEAN — no differences." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'='*60}\n")
    sys.exit(0 if clean else 1)
