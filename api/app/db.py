"""Database access: a small connection pool and helpers that run the SQL files in app/sql.

Every session is read-only and has a statement timeout: the API never changes data.
"""

from functools import cache
from pathlib import Path
from typing import Any

from psycopg_pool import ConnectionPool

from app.config import settings

SQL_DIR = Path(__file__).parent / "sql"

pool = ConnectionPool(
    settings.database_url,
    min_size=settings.pool_min_size,
    max_size=settings.pool_max_size,
    open=False,
    kwargs={
        "autocommit": True,
        "options": (
            "-c default_transaction_read_only=on "
            f"-c statement_timeout={settings.statement_timeout_ms}"
        ),
    },
)


@cache
def sql(name: str) -> str:
    """Text of app/sql/<name>.sql (read once)."""
    return (SQL_DIR / f"{name}.sql").read_text()


def fetch_value(query: str, params: dict[str, Any] | None = None) -> Any:
    """First column of the first row (or None)."""
    with pool.connection() as conn:
        row = conn.execute(query, params or {}).fetchone()
    return row[0] if row else None


def fetch_all(query: str, params: dict[str, Any] | None = None) -> list[tuple]:
    with pool.connection() as conn:
        return conn.execute(query, params or {}).fetchall()
