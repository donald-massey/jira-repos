"""DAG comparison — paste DAG source and fill variables below, then run: python compare.py"""

import difflib
import sys

# fmt: off

PROD_DAG = """
# paste prod DAG source here
"""

DEV_DAG = """
# paste dev DAG source here
"""

PROD_VARIABLES = {
    # "key": "value",
}

DEV_VARIABLES = {
    # "key": "value",
}

# fmt: on

# ---------------------------------------------------------------------------

def compare_source() -> bool:
    print(f"\n{'='*60}\nDAG SOURCE DIFF\n{'='*60}")
    diff = list(difflib.unified_diff(
        PROD_DAG.splitlines(keepends=True),
        DEV_DAG.splitlines(keepends=True),
        fromfile="prod",
        tofile="dev",
    ))
    if not diff:
        print("  No differences.")
        return True
    print("".join(diff))
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
    clean = compare_source() & compare_variables()
    print(f"\n{'='*60}")
    print("RESULT:", "CLEAN — no differences." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'='*60}\n")
    sys.exit(0 if clean else 1)
