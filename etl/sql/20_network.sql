-- Routing network: speeds, scenarios, clean edge/vertex tables and connected components.
-- Input : net.ways, net.ways_vertices_pgr, net.configuration (osm2pgrouting), config/*.csv
-- Output: net.speeds, net.scenarios, net.edges, net.vertices
--
-- Travel costs are NOT stored on the edges: svc.edges_sql() (sql/40_functions.sql) computes
-- them from length_m, net.speeds and net.scenarios, so speed scenarios need no re-import.

BEGIN;

-- ------------------------------------------------------------------ assumptions
DROP TABLE IF EXISTS net.speeds CASCADE;
CREATE TABLE net.speeds (
    highway   text PRIMARY KEY,
    drive_kmh numeric CHECK (drive_kmh > 0),   -- NULL = not drivable (walking only)
    note      text
);
\copy net.speeds FROM 'config/speeds.csv' WITH (FORMAT csv, HEADER)

DROP TABLE IF EXISTS net.scenarios CASCADE;
CREATE TABLE net.scenarios (
    scenario     text PRIMARY KEY,
    applies_to   text    NOT NULL CHECK (applies_to IN ('walk', 'drive', 'both')),
    walk_kmh     numeric NOT NULL CHECK (walk_kmh > 0),
    drive_factor numeric NOT NULL CHECK (drive_factor > 0),
    description  text
);
\copy net.scenarios FROM 'config/scenarios.csv' WITH (FORMAT csv, HEADER)

-- Every road class imported by osm2pgrouting must have a row in speeds.csv.
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(DISTINCT c.tag_value, ', ') INTO missing
    FROM net.ways w
    JOIN net.configuration c USING (tag_id)
    LEFT JOIN net.speeds s ON s.highway = c.tag_value
    WHERE s.highway IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Road classes without a row in speeds.csv: %', missing;
    END IF;
END $$;

-- ------------------------------------------------------------------ edges
-- osm2pgrouting marks one-way direction with negative costs:
--   cost < 0         -> cannot be driven source -> target
--   reverse_cost < 0 -> cannot be driven target -> source
-- Geometry runs from source to target. Self-loops are dropped (they never shorten a route).
DROP TABLE IF EXISTS net.edges CASCADE;
CREATE TABLE net.edges AS
SELECT w.gid                                  AS id,
       w.osm_id,
       w.source,
       w.target,
       c.tag_value                            AS highway,
       w.name,
       w.length_m,
       s.drive_kmh,
       (w.cost >= 0)                          AS fwd_ok,
       (w.reverse_cost >= 0)                  AS bwd_ok,
       NULL::bigint                           AS comp_walk,
       NULL::bigint                           AS comp_drive,
       false                                  AS walk_ok,   -- set below: in main walk component
       false                                  AS drive_ok,  -- set below: drivable and in main drive component
       ST_Transform(w.the_geom, 32628)::geometry(LineString, 32628) AS geom
FROM net.ways w
JOIN net.configuration c USING (tag_id)
JOIN net.speeds s ON s.highway = c.tag_value
WHERE w.source <> w.target;

ALTER TABLE net.edges ADD PRIMARY KEY (id);
CREATE INDEX ON net.edges (source);
CREATE INDEX ON net.edges (target);
CREATE INDEX ON net.edges USING gist (geom);

-- ------------------------------------------------------------------ vertices
DROP TABLE IF EXISTS net.vertices CASCADE;
CREATE TABLE net.vertices AS
SELECT v.id,
       v.osm_id,
       NULL::bigint AS comp_walk,
       NULL::bigint AS comp_drive,
       false        AS in_main_walk,
       false        AS in_main_drive,
       ST_Transform(v.the_geom, 32628)::geometry(Point, 32628) AS geom
FROM net.ways_vertices_pgr v
WHERE EXISTS (SELECT 1 FROM net.edges e WHERE e.source = v.id OR e.target = v.id);

ALTER TABLE net.vertices ADD PRIMARY KEY (id);
CREATE INDEX ON net.vertices USING gist (geom);

-- ------------------------------------------------------------------ components
-- Walking: undirected graph, connected components.
UPDATE net.vertices v
SET comp_walk = cc.component
FROM pgr_connectedComponents(
       'SELECT id, source, target, length_m AS cost, length_m AS reverse_cost FROM net.edges') cc
WHERE cc.node = v.id;

-- Driving: directed graph, STRONGLY connected components. A node outside the main strong
-- component cannot both reach and be reached from the rest (e.g. a one-way dead end).
UPDATE net.vertices v
SET comp_drive = sc.component
FROM pgr_strongComponents(
       'SELECT id, source, target,
               CASE WHEN fwd_ok THEN length_m ELSE -1 END AS cost,
               CASE WHEN bwd_ok THEN length_m ELSE -1 END AS reverse_cost
        FROM net.edges WHERE drive_kmh IS NOT NULL') sc
WHERE sc.node = v.id;

-- Main component = the one with the most road length.
WITH walk_main AS (
    SELECT v.comp_walk FROM net.edges e JOIN net.vertices v ON v.id = e.source
    GROUP BY v.comp_walk ORDER BY sum(e.length_m) DESC LIMIT 1
)
UPDATE net.vertices SET in_main_walk = (comp_walk = (SELECT comp_walk FROM walk_main));

WITH drive_main AS (
    SELECT v.comp_drive FROM net.edges e JOIN net.vertices v ON v.id = e.source
    WHERE e.drive_kmh IS NOT NULL AND v.comp_drive IS NOT NULL
    GROUP BY v.comp_drive ORDER BY sum(e.length_m) DESC LIMIT 1
)
UPDATE net.vertices SET in_main_drive = COALESCE(comp_drive = (SELECT comp_drive FROM drive_main), false);

UPDATE net.edges e
SET comp_walk  = vs.comp_walk,
    comp_drive = vs.comp_drive,
    walk_ok    = vs.in_main_walk AND vt.in_main_walk,
    drive_ok   = e.drive_kmh IS NOT NULL AND vs.in_main_drive AND vt.in_main_drive
FROM net.vertices vs, net.vertices vt
WHERE vs.id = e.source AND vt.id = e.target;

-- The raw osm2pgrouting tables are no longer needed by later steps, but are kept for inspection.
ANALYZE net.edges;
ANALYZE net.vertices;

-- ------------------------------------------------------------------ log
SELECT meta.log('network', 'edges',                 (SELECT count(*) FROM net.edges));
SELECT meta.log('network', 'vertices',              (SELECT count(*) FROM net.vertices));
SELECT meta.log('network', 'road_km',               (SELECT round(sum(length_m)::numeric / 1000) FROM net.edges));
SELECT meta.log('network', 'drivable_km',           (SELECT round(sum(length_m)::numeric / 1000) FROM net.edges WHERE drive_kmh IS NOT NULL));
SELECT meta.log('network', 'oneway_edges',          (SELECT count(*) FROM net.edges WHERE NOT (fwd_ok AND bwd_ok)));
SELECT meta.log('network', 'walk_components',       (SELECT count(DISTINCT comp_walk) FROM net.vertices));
SELECT meta.log('network', 'walk_main_km_pct',      (SELECT round((100 * sum(length_m) FILTER (WHERE walk_ok) / sum(length_m))::numeric, 2) FROM net.edges));
SELECT meta.log('network', 'drive_components',      (SELECT count(DISTINCT comp_drive) FROM net.vertices WHERE comp_drive IS NOT NULL));
SELECT meta.log('network', 'drive_main_km_pct',     (SELECT round((100 * sum(length_m) FILTER (WHERE drive_ok) / sum(length_m))::numeric, 2) FROM net.edges WHERE drive_kmh IS NOT NULL));

COMMIT;
