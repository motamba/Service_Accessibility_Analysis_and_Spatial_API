-- Schemas and bookkeeping tables. Safe to run repeatedly.
--   ref  : input/reference layers (boundaries, water, land, buildings)
--   net  : routing graph
--   svc  : facilities and per-node results
--   res  : published results (service areas, gaps, coverage, hex surface)
--   meta : import counts, data provenance, pipeline runs
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- name similarity when merging facility sources

CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS net;
CREATE SCHEMA IF NOT EXISTS svc;
CREATE SCHEMA IF NOT EXISTS res;
CREATE SCHEMA IF NOT EXISTS meta;

-- One row per measured quantity per step; the README's data-quality table is built from this.
CREATE TABLE IF NOT EXISTS meta.import_log (
    id        serial PRIMARY KEY,
    step      text        NOT NULL,
    item      text        NOT NULL,
    value     numeric     NOT NULL,
    logged_at timestamptz NOT NULL DEFAULT now()
);

-- Provenance of each input dataset.
CREATE TABLE IF NOT EXISTS meta.dataset (
    name         text PRIMARY KEY,
    source_url   text,
    licence      text,
    data_date    text,            -- date of the data itself (e.g. OSM replication timestamp)
    retrieved_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS meta.pipeline_run (
    id          serial PRIMARY KEY,
    finished_at timestamptz NOT NULL DEFAULT now(),
    note        text
);

-- Helper: replace the log rows of a step, so re-running a step does not duplicate them.
CREATE OR REPLACE FUNCTION meta.log(p_step text, p_item text, p_value numeric)
RETURNS void LANGUAGE sql AS $$
    DELETE FROM meta.import_log WHERE step = p_step AND item = p_item;
    INSERT INTO meta.import_log (step, item, value) VALUES (p_step, p_item, p_value);
$$;
