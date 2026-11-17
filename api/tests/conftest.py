"""Test database set-up.

A fresh database `gis_test` is created on the same PostgreSQL server as the real data. It gets the
pipeline's schema script and routing functions (etl/sql) plus the synthetic network in
tests/fixtures, so the tests run the real SQL against inputs with known answers.

Environment:
  TEST_DATABASE_ADMIN_URL  connection to an existing database on the server (default: local
                           Docker database on port 5433)
  ETL_SQL_DIR              folder with the pipeline SQL (default: ../etl/sql from this repo)
"""

import os
from pathlib import Path

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

ADMIN_URL = os.environ.get(
    "TEST_DATABASE_ADMIN_URL", "postgresql://gis:gis@localhost:5433/postgres"
)
SQL_DIR = Path(os.environ.get("ETL_SQL_DIR", Path(__file__).resolve().parents[2] / "etl" / "sql"))
FIXTURES = Path(__file__).parent / "fixtures"
TEST_DB = "gis_test"


@pytest.fixture(scope="session")
def db():
    """Autocommit connection to a freshly built test database."""
    with psycopg.connect(ADMIN_URL, autocommit=True) as admin:
        admin.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
        admin.execute(f"CREATE DATABASE {TEST_DB}")

    with psycopg.connect(make_conninfo(ADMIN_URL, dbname=TEST_DB), autocommit=True) as conn:
        conn.execute("SET client_min_messages = warning")
        conn.execute((SQL_DIR / "00_schemas.sql").read_text())
        conn.execute((FIXTURES / "grid_network.sql").read_text())
        conn.execute((SQL_DIR / "40_functions.sql").read_text())
        yield conn


def node_access(conn, type_, mode, scenario="base", max_seconds=3600):
    """Run the pipeline function and return {node_id: (facility_id, seconds)}."""
    conn.execute(
        "SELECT svc.compute_node_access(%s, %s, %s, %s)", (type_, mode, scenario, max_seconds)
    )
    rows = conn.execute(
        "SELECT node_id, facility_id, seconds FROM svc.node_access "
        "WHERE type = %s AND mode = %s AND scenario = %s",
        (type_, mode, scenario),
    ).fetchall()
    return {node: (facility, seconds) for node, facility, seconds in rows}
