"""
tblS3Image_schema.py
====================
LND-8482 — dump the tblS3Image column list so we can confirm the repair INSERT
sets every non-defaulted NOT NULL column. Post-cleanup deleted the rows, so the
common repair path is INSERT (not UPDATE); a missing required column would fail
every insert on --commit.

    python query_3/tblS3Image_schema.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils.database_utils import connect_countyscanstitle  # noqa: E402


def _load_env() -> None:
    try:
        from dotenv import load_dotenv
        env = Path(__file__).resolve().parent.parent / ".env"
        if env.exists():
            load_dotenv(env)
    except ImportError:
        pass


# Columns the repair INSERT currently sets.
INSERT_COLS = {"recordID", "s3FilePath", "pageCount", "fileSizeBytes", "_ModifiedBy", "_ModifiedDateTime"}


def main() -> None:
    _load_env()
    conn = connect_countyscanstitle()
    try:
        rows = conn.execute_query("""
            SELECT c.name              AS column_name,
                   t.name              AS data_type,
                   c.is_nullable,
                   c.is_identity,
                   c.is_computed,
                   dc.definition       AS default_definition
            FROM sys.columns c
            JOIN sys.types  t  ON t.user_type_id = c.user_type_id
            LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
            WHERE c.object_id = OBJECT_ID('countyScansTitle.dbo.tblS3Image')
            ORDER BY c.column_id
        """)
    finally:
        conn.close()

    if not rows:
        print("tblS3Image not found (or no permission).")
        return

    print(f"{'column':24s} {'type':14s} {'null?':6s} {'ident':6s} {'comp':5s} {'default':20s} set?")
    missing_required = []
    for r in rows:
        nullable = bool(r["is_nullable"])
        identity = bool(r["is_identity"])
        computed = bool(r["is_computed"])
        has_default = r["default_definition"] is not None
        set_by_insert = r["column_name"] in INSERT_COLS
        # A column the INSERT must supply: NOT NULL, no default, not identity, not computed.
        required = (not nullable) and (not has_default) and (not identity) and (not computed)
        flag = "SET" if set_by_insert else ("<-- MISSING" if required else "")
        if required and not set_by_insert:
            missing_required.append(r["column_name"])
        print(f"{r['column_name']:24s} {r['data_type']:14s} "
              f"{'NULL' if nullable else 'NOT':6s} {'yes' if identity else '':6s} "
              f"{'yes' if computed else '':5s} {(r['default_definition'] or ''):20.20s} {flag}")

    print()
    if missing_required:
        print(f"INSERT WILL FAIL — required columns not set: {missing_required}")
    else:
        print("OK — INSERT sets every non-defaulted NOT NULL column.")


if __name__ == "__main__":
    main()
