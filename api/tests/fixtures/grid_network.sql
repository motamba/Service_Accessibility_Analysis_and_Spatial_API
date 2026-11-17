-- Synthetic road network with answers that can be worked out by hand.
-- Loaded into a separate test database, together with the REAL pipeline functions
-- (etl/sql/40_functions.sql), so the tests exercise the same SQL that runs on Greater Banjul.
--
--   row 4   21 -- 22 -- 23 -- 24 -- 25        node id = row * 5 + col + 1
--           |     |     |     |     |         spacing 100 m (EPSG:32628, near Banjul)
--   row 3   16 -- 17 -- 18 -- 19 -- 20
--           |     |     |     |     |         walk 4.5 km/h  -> 80 s per edge
--   row 2   11 -- 12 -- 13 -- 14 -- 15        drive 36 km/h  -> 10 s per edge
--           |     |     |     |     |
--   row 1    6 --  7 --  8 --  9 -- 10        edge 1 -> 2 is ONE-WAY for driving
--           |     |     |     |     |         (allowed 1 -> 2 only)
--   row 0    1 ->  2 --  3 --  4 --  5
--
--   island: 101 -- 102, 1 km away and not connected (outside the main network)
--
-- Facilities
--   1  health  at node 1
--   2  school  at node 21
--   3  school  at node 5
--   4  school  at node 5   (shares a node with facility 3)

-- ------------------------------------------------------------------ scenarios
CREATE TABLE net.scenarios (
    scenario     text PRIMARY KEY,
    applies_to   text    NOT NULL,
    walk_kmh     numeric NOT NULL,
    drive_factor numeric NOT NULL,
    description  text
);
INSERT INTO net.scenarios VALUES
    ('base',       'both',  4.5, 1.0, 'base'),
    ('walk_fast',  'walk',  5.0, 1.0, 'faster walking'),
    ('drive_slow', 'drive', 4.5, 0.5, 'half driving speed');

-- ------------------------------------------------------------------ edges
CREATE TABLE net.edges AS
WITH n AS (
    SELECT r, c, (r * 5 + c + 1)::bigint AS id,
           ST_SetSRID(ST_MakePoint(330000 + c * 100, 1480000 + r * 100), 32628) AS pt
    FROM generate_series(0, 4) r, generate_series(0, 4) c
), e AS (
    SELECT a.id AS source, b.id AS target, ST_MakeLine(a.pt, b.pt) AS geom
    FROM n a JOIN n b ON b.r = a.r AND b.c = a.c + 1          -- horizontal
    UNION ALL
    SELECT a.id, b.id, ST_MakeLine(a.pt, b.pt)
    FROM n a JOIN n b ON b.c = a.c AND b.r = a.r + 1          -- vertical
)
SELECT row_number() OVER (ORDER BY source, target)::bigint AS id,
       source, target,
       100.0::float8  AS length_m,
       36.0::numeric  AS drive_kmh,
       true AS fwd_ok, true AS bwd_ok, true AS walk_ok, true AS drive_ok,
       geom::geometry(LineString, 32628) AS geom
FROM e;

-- one-way street: 1 -> 2 only
UPDATE net.edges SET bwd_ok = false WHERE source = 1 AND target = 2;

-- disconnected island, not part of the main network
INSERT INTO net.edges VALUES
    (1000, 101, 102, 100.0, 36.0, true, true, false, false,
     ST_SetSRID(ST_MakeLine(ST_MakePoint(331000, 1480000), ST_MakePoint(331100, 1480000)), 32628));

-- ------------------------------------------------------------------ facilities
CREATE TABLE svc.facilities (
    id   int PRIMARY KEY,
    type text NOT NULL
);
INSERT INTO svc.facilities VALUES (1, 'health'), (2, 'school'), (3, 'school'), (4, 'school');

CREATE TABLE svc.facility_nodes (
    facility_id int    NOT NULL,
    mode        text   NOT NULL,
    node_id     bigint NOT NULL,
    PRIMARY KEY (facility_id, mode)
);
INSERT INTO svc.facility_nodes
SELECT f, m, n
FROM (VALUES (1, 1), (2, 21), (3, 5), (4, 5)) AS fac(f, n),
     (VALUES ('walk'), ('drive')) AS mode(m);

-- ------------------------------------------------------------------ cell -> edge links
-- Cells are linked to edges directly here (the real pipeline does this in 55_grid.sql).
CREATE TABLE svc.cell_edges (
    cell_id int    NOT NULL,
    mode    text   NOT NULL,
    edge_id bigint NOT NULL,
    frac    double precision NOT NULL,
    dist_m  double precision NOT NULL,
    PRIMARY KEY (mode, cell_id, edge_id)
);
-- cell 1: halfway along the one-way edge 1 -> 2
INSERT INTO svc.cell_edges
SELECT 1, m, (SELECT id FROM net.edges WHERE source = 1 AND target = 2), 0.5, 20
FROM (VALUES ('walk'), ('drive')) AS mode(m);
