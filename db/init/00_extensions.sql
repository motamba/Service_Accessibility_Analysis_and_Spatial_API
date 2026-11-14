-- Runs once, when the database volume is first created.
-- Schemas and tables are created by the ETL pipeline (etl/sql/00_schemas.sql), so the
-- pipeline also works against a database that was not created by this container.
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;
