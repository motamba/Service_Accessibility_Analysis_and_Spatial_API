-- Analysis grid: 50 m square cells over the land part of the study area.
-- Every result (service areas, gaps, coverage, travel-time surface) is built from per-cell travel
-- times, so the map and the statistics always agree.
-- Input : ref.land, ref.buildings, net.edges
-- Output: ref.grid, ref.building_cell, svc.cell_edges
--
-- Vars  : :cell_m (cell size), :access_m (max distance from a cell centre to a usable road)

BEGIN;

-- ------------------------------------------------------------------ cells
-- ST_SquareGrid is aligned on multiples of the cell size, so the cell of any point is simply
-- (floor(x / size), floor(y / size)) - used below to place buildings without a spatial join.
DROP TABLE IF EXISTS ref.grid CASCADE;
CREATE TABLE ref.grid AS
SELECT row_number() OVER (ORDER BY g.i, g.j)::int AS cell_id,
       g.i, g.j,
       g.geom::geometry(Polygon, 32628)              AS geom,
       ST_Centroid(g.geom)::geometry(Point, 32628)   AS pt
FROM ref.land l,
     ST_SquareGrid(:cell_m, l.geom) g
WHERE ST_Intersects(g.geom, l.geom);

ALTER TABLE ref.grid ADD PRIMARY KEY (cell_id);
CREATE UNIQUE INDEX ON ref.grid (i, j);
CREATE INDEX ON ref.grid USING gist (pt);
ANALYZE ref.grid;

-- ------------------------------------------------------------------ buildings -> cells
DROP TABLE IF EXISTS ref.building_cell;
CREATE TABLE ref.building_cell AS
SELECT b.id AS building_id, g.cell_id
FROM ref.buildings b
JOIN ref.grid g ON g.i = floor(ST_X(b.geom) / :cell_m)::int
               AND g.j = floor(ST_Y(b.geom) / :cell_m)::int;

ALTER TABLE ref.building_cell ADD PRIMARY KEY (building_id);
CREATE INDEX ON ref.building_cell (cell_id);

-- ------------------------------------------------------------------ cells -> nearby roads
-- Up to 3 nearest usable edges within :access_m of the cell centre, per mode, with the position
-- of the closest point along the edge (0 = source end, 1 = target end). Cells with no road
-- within :access_m have no rows: they are "no road access" whatever the travel time.
DROP TABLE IF EXISTS svc.cell_edges;
CREATE TABLE svc.cell_edges (
    cell_id int    NOT NULL,
    mode    text   NOT NULL,
    edge_id bigint NOT NULL,
    frac    double precision NOT NULL,
    dist_m  double precision NOT NULL,
    PRIMARY KEY (mode, cell_id, edge_id)
);

INSERT INTO svc.cell_edges
SELECT g.cell_id, m.mode, e.id, ST_LineLocatePoint(e.geom, g.pt), e.d
FROM ref.grid g
CROSS JOIN (VALUES ('walk'), ('drive')) AS m(mode)
CROSS JOIN LATERAL (
    SELECT ed.id, ed.geom, ed.geom <-> g.pt AS d
    FROM net.edges ed
    WHERE CASE m.mode WHEN 'walk' THEN ed.walk_ok ELSE ed.drive_ok END
      AND ST_DWithin(ed.geom, g.pt, :access_m)
    ORDER BY ed.geom <-> g.pt
    LIMIT 3) e;

ANALYZE svc.cell_edges;

SELECT meta.log('grid', 'cells',                 (SELECT count(*) FROM ref.grid));
SELECT meta.log('grid', 'cell_size_m',           :cell_m);
SELECT meta.log('grid', 'buildings_in_cells',    (SELECT count(*) FROM ref.building_cell));
SELECT meta.log('grid', mode || '_cells_with_road_pct',
                round(100.0 * count(DISTINCT cell_id) / (SELECT count(*) FROM ref.grid), 1))
FROM svc.cell_edges GROUP BY mode;

COMMIT;
