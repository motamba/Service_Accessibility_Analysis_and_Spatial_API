-- Published results: service areas, gaps and building coverage per
-- facility type x mode x scenario x time band.
-- Input : svc.node_access, svc.cell_edges, ref.grid, ref.land, ref.buildings, ref.building_cell
-- Output: res.bands, svc.cell_access, res.service_areas, res.gaps, res.coverage

BEGIN;

-- ------------------------------------------------------------------ time bands
DROP TABLE IF EXISTS res.bands CASCADE;
CREATE TABLE res.bands (
    mode    text NOT NULL,
    minutes int  NOT NULL,
    PRIMARY KEY (mode, minutes)
);
INSERT INTO res.bands VALUES
    ('walk', 15), ('walk', 30), ('walk', 60),
    ('drive', 5), ('drive', 10), ('drive', 15);

-- ------------------------------------------------------------------ travel time per cell
TRUNCATE svc.cell_access;
SELECT svc.compute_cell_access(t.type, m.mode, s.scenario)
FROM (VALUES ('health'), ('school')) AS t(type)
CROSS JOIN (VALUES ('walk'), ('drive')) AS m(mode)
JOIN net.scenarios s ON s.applies_to IN (m.mode, 'both');
ANALYZE svc.cell_access;

CREATE TEMP TABLE combos ON COMMIT DROP AS
SELECT DISTINCT type, mode, scenario FROM svc.cell_access;

-- ------------------------------------------------------------------ service areas
-- Union of the cells reachable within the band (cells form a coverage, so ST_CoverageUnion
-- is fast), clipped to land.
DROP TABLE IF EXISTS res.service_areas CASCADE;
CREATE TABLE res.service_areas (
    type     text    NOT NULL,
    mode     text    NOT NULL,
    scenario text    NOT NULL,
    minutes  int     NOT NULL,
    area_km2 numeric,
    geom     geometry(MultiPolygon, 32628) NOT NULL,
    PRIMARY KEY (type, mode, scenario, minutes)
);

INSERT INTO res.service_areas (type, mode, scenario, minutes, geom)
SELECT c.type, c.mode, c.scenario, b.minutes,
       COALESCE(ST_Multi(ST_CollectionExtract(ST_Intersection(u.geom, l.geom), 3)),
                ST_SetSRID('MULTIPOLYGON EMPTY'::geometry, 32628))
FROM combos c
JOIN res.bands b ON b.mode = c.mode
CROSS JOIN ref.land l
CROSS JOIN LATERAL (
    -- ST_CoverageUnion returns SRID 0 in PostGIS 3.5 / GEOS 3.9: set it back.
    SELECT ST_SetSRID(ST_CoverageUnion(g.geom), 32628) AS geom
    FROM svc.cell_access ca JOIN ref.grid g USING (cell_id)
    WHERE ca.type = c.type AND ca.mode = c.mode AND ca.scenario = c.scenario
      AND ca.seconds <= b.minutes * 60) u;

UPDATE res.service_areas SET area_km2 = round((ST_Area(geom) / 1e6)::numeric, 2);
CREATE INDEX ON res.service_areas USING gist (geom);

-- ------------------------------------------------------------------ gaps
-- Land beyond the band, one row per separate area; slivers under 0.5 ha are dropped.
DROP TABLE IF EXISTS res.gaps CASCADE;
CREATE TABLE res.gaps (
    id          serial PRIMARY KEY,
    type        text    NOT NULL,
    mode        text    NOT NULL,
    scenario    text    NOT NULL,
    minutes     int     NOT NULL,
    area_km2    numeric,
    n_buildings int,
    geom        geometry(Polygon, 32628) NOT NULL
);

INSERT INTO res.gaps (type, mode, scenario, minutes, geom)
SELECT sa.type, sa.mode, sa.scenario, sa.minutes, d.geom
FROM res.service_areas sa
CROSS JOIN ref.land l
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(ST_Difference(l.geom, sa.geom), 3)) d
WHERE ST_Area(d.geom) >= 5000;

CREATE INDEX ON res.gaps USING gist (geom);
CREATE INDEX ON res.gaps (type, mode, scenario, minutes);

UPDATE res.gaps g
SET area_km2    = round((ST_Area(g.geom) / 1e6)::numeric, 3),
    n_buildings = (SELECT count(*) FROM ref.buildings b WHERE ST_Intersects(b.geom, g.geom));

-- ------------------------------------------------------------------ coverage
-- Share of buildings whose cell is within the band.
DROP TABLE IF EXISTS res.coverage CASCADE;
CREATE TABLE res.coverage AS
SELECT c.type, c.mode, c.scenario, b.minutes,
       count(*) FILTER (WHERE ca.seconds <= b.minutes * 60) AS buildings_in,
       count(*)                                             AS buildings_total,
       round(100.0 * count(*) FILTER (WHERE ca.seconds <= b.minutes * 60) / count(*), 1) AS pct
FROM combos c
JOIN res.bands b ON b.mode = c.mode
CROSS JOIN ref.building_cell bc
LEFT JOIN svc.cell_access ca
       ON ca.cell_id = bc.cell_id AND ca.type = c.type AND ca.mode = c.mode AND ca.scenario = c.scenario
GROUP BY c.type, c.mode, c.scenario, b.minutes;

ALTER TABLE res.coverage ADD PRIMARY KEY (type, mode, scenario, minutes);

-- ------------------------------------------------------------------ log (base scenario)
SELECT meta.log('coverage', type || '_' || mode || '_' || minutes || 'min_pct', pct)
FROM res.coverage WHERE scenario = 'base';

COMMIT;
