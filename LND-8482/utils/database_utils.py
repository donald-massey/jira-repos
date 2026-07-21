"""
database_utils.py
=================
SQL Server connection wrapper. Ported from LND-8093 for the LND-8482 repair.

Wraps a real pyodbc connection. Requires ODBC Driver 17 for SQL Server.
"""
from __future__ import annotations

import time
import random
import logging
from typing import Any

logger = logging.getLogger(__name__)


class DatabaseConnection:
    """SQL Server connection via pyodbc with deadlock-retrying DML helpers."""

    def __init__(
        self,
        db_name: str,
        server: str,
        username: str = "",
        password: str = "",
        driver: str = "ODBC Driver 17 for SQL Server",
    ):
        self.db_name = db_name
        self.server = server
        self.username = username
        self.password = password
        self.driver = driver
        self._conn = None
        self._in_transaction = False
        logger.info("DatabaseConnection initialised: server=%s db=%s", server, db_name)

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    def connect(self) -> None:
        """Open a pyodbc connection to the SQL Server database."""
        import pyodbc  # noqa: PLC0415

        conn_str = (
            f"DRIVER={{{self.driver}}};"
            f"SERVER={self.server};"
            f"DATABASE={self.db_name};"
            f"UID={self.username};"
            f"PWD={self.password};"
            f"TrustServerCertificate=yes;"
        )
        self._conn = pyodbc.connect(conn_str, autocommit=False)
        logger.info("[%s] Connected to %s", self.db_name, self.server)

    def close(self) -> None:
        """Close the pyodbc connection."""
        if self._conn:
            self._conn.close()
            self._conn = None
        logger.info("[%s] Connection closed", self.db_name)

    def begin_transaction(self) -> None:
        self._in_transaction = True
        logger.info("[%s] BEGIN TRANSACTION", self.db_name)

    def commit(self) -> None:
        if not self._in_transaction:
            raise RuntimeError("No active transaction to commit.")
        if self._conn:
            self._conn.commit()
        self._in_transaction = False
        logger.info("[%s] COMMIT", self.db_name)

    def rollback(self) -> None:
        if self._conn:
            self._conn.rollback()
        self._in_transaction = False
        logger.info("[%s] ROLLBACK", self.db_name)

    # ------------------------------------------------------------------
    # Query helpers
    # ------------------------------------------------------------------

    def execute_query(self, sql: str, params: list | None = None) -> list[dict[str, Any]]:
        """Execute a SELECT and return rows as a list of dicts."""
        if self._conn is None:
            raise RuntimeError(f"[{self.db_name}] Not connected. Call connect() first.")
        cursor = self._conn.cursor()
        if params:
            cursor.execute(sql, params)
        else:
            cursor.execute(sql)
        if cursor.description is None:
            return []
        columns = [col[0] for col in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]

    def execute_update(self, sql: str, params: list | None = None, max_retries: int = 5) -> int:
        """Execute an INSERT/UPDATE/DELETE/DDL statement; retries deadlocks."""
        if self._conn is None:
            raise RuntimeError(f"[{self.db_name}] Not connected. Call connect() first.")
        logger.info("[%s] UPDATE: %s | params=%s", self.db_name, sql.strip(), params)

        for attempt in range(max_retries):
            try:
                cursor = self._conn.cursor()
                if params:
                    cursor.execute(sql, params)
                else:
                    cursor.execute(sql)
                if not self._in_transaction:
                    self._conn.commit()
                rows_affected = cursor.rowcount
                logger.info("[%s] %d row(s) affected.", self.db_name, rows_affected)
                return rows_affected
            except Exception as e:
                is_deadlock = "deadlock" in str(e).lower()
                if is_deadlock and self._in_transaction:
                    # The reconnect below drops the caller's open transaction. Inside an
                    # explicit transaction, let the deadlock propagate so the caller can
                    # roll back and retry the whole unit atomically.
                    logger.error("[%s] Deadlock inside an explicit transaction — not retrying here.", self.db_name)
                    raise
                if is_deadlock and attempt < max_retries - 1:
                    wait = (2 ** attempt) + random.uniform(0, 1)
                    logger.warning(
                        "[%s] Deadlock on attempt %d/%d, retrying in %.1fs",
                        self.db_name, attempt + 1, max_retries, wait,
                    )
                    time.sleep(wait)
                    try:
                        self.close()
                        self.connect()
                    except Exception as reconnect_err:
                        logger.error("[%s] Reconnect failed after deadlock: %s", self.db_name, reconnect_err)
                        raise e from reconnect_err
                else:
                    logger.error("[%s] execute_update failed after %d attempt(s): %s", self.db_name, attempt + 1, e)
                    raise


def connect_countyscanstitle() -> DatabaseConnection:
    """Build and open a countyScansTitle connection from cstitle_* env vars."""
    import os

    conn = DatabaseConnection(
        db_name="countyScansTitle",
        server=os.environ.get("cstitle_server", ""),
        username=os.environ.get("cstitle_username", ""),
        password=os.environ.get("cstitle_password", ""),
    )
    conn.connect()
    return conn
