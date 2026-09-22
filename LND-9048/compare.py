"""DAG comparison — paste DAG source and fill variables below, then run: python compare.py"""

import difflib
import json
import sys

# fmt: off

PROD_DAG = '''
# paste prod DAG source here
'''

DEV_DAG = '''
# paste dev DAG source here
'''

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


def _flat_diff(prod, dev, path=""):
    """Recursively yield (path, prod_val, dev_val) for every leaf that differs."""
    if isinstance(prod, dict) and isinstance(dev, dict):
        for k in sorted(set(prod) | set(dev)):
            child = f"{path}.{k}" if path else k
            if k not in dev:
                yield child, prod[k], "<missing>"
            elif k not in prod:
                yield child, "<missing>", dev[k]
            else:
                yield from _flat_diff(prod[k], dev[k], child)
    elif prod != dev:
        yield path, prod, dev


def compare_variables() -> bool:
    print(f"\n{'='*60}\nVARIABLES DIFF\n{'='*60}")
    diffs = list(_flat_diff(PROD_VARIABLES, DEV_VARIABLES))
    if not diffs:
        print("  No differences.")
        return True
    for path, prod_val, dev_val in diffs:
        print(f"\n  ~ {path}")
        print(f"      Prod: {json.dumps(prod_val, indent=2) if isinstance(prod_val, (dict, list)) else prod_val!r}")
        print(f"      Dev:  {json.dumps(dev_val, indent=2) if isinstance(dev_val, (dict, list)) else dev_val!r}")
    return False


if __name__ == "__main__":
    clean = compare_source() & compare_variables()
    print(f"\n{'='*60}")
    print("RESULT:", "CLEAN — no differences." if clean else "DIFFERENCES DETECTED — see above.")
    print(f"{'='*60}\n")
    sys.exit(0 if clean else 1)
