-- Travel-time surface for the web map: hexagons aggregated from the 50 m analysis cells.
-- The 112k cells are too many to draw in a browser; ~2,600 hexagons are light enough and still
-- show the pattern. The hexagon shapes are sent once; the times per type/mode/scenario are
-- sent as a small table and joined in the browser.
-- Input : ref.grid, ref.land, ref.building_cell, svc.cell_access
-- Output: res.hex, res.hex_access
-- Vars  : :hex_m (hexagon side length, metres)

BEGIN;

-- ------------------------------------------------------------------ hexagons
DROP TABLE IF EXISTS res.hex CASCADE;
CREATE TABLE res.hex AS
SELECT row_number() OVER (ORDER BY h.i, h.j)::int                        AS hex_id,
       h.geom::geometry(Polygon, 32628)                                   AS geom_full,
       ST_Multi(ST_CollectionExtract(ST_Intersection(h.geom, l.geom), 3))::geometry(MultiPolygon, 32628) AS geom,
       0                                                                  AS n_buildings
FROM ref.land l,
     ST_HexagonGrid(:hex_m, l.geom) h
WHERE ST_Intersects(h.geom, l.geom);

DELETE FROM res.hex WHERE ST_IsEmpty(geom) OR ST_Area(geom) < 100;   -- tiny coastal slivers
ALTER TABLE res.hex ADD PRIMARY KEY (hex_id);

-- Web version, prepared once: WGS 84, coastline-cut hexagons simplified by 5 m.
ALTER TABLE res.hex ADD COLUMN geom_web geometry(MultiPolygon, 4326);
UPDATE res.hex SET geom_web = ST_Transform(ST_Multi(ST_SimplifyPreserveTopology(geom, 5)), 4326);
CREATE INDEX ON res.hex USING gist (geom_full);

-- Each analysis cell belongs to the hexagon that contains its centre.
DROP TABLE IF EXISTS res.hex_cell;
CREATE TABLE res.hex_cell AS
SELECT g.cell_id, h.hex_id
FROM ref.grid g
JOIN res.hex h ON ST_Within(g.pt, h.geom_full);
ALTER TABLE res.hex_cell ADD PRIMARY KEY (cell_id);
CREATE INDEX ON res.hex_cell (hex_id);

UPDATE res.hex h
SET n_buildings = b.n
FROM (SELECT hc.hex_id, count(*) AS n
      FROM ref.building_cell bc JOIN res.hex_cell hc USING (cell_id)
      GROUP BY hc.hex_id) b
WHERE b.hex_id = h.hex_id;

-- ------------------------------------------------------------------ times per hexagon
-- Median time of the hexagon's cells that have road access, and the facility most of those
-- cells are nearest to. Hexagons with no road within 150 m of any cell have no row.
DROP TABLE IF EXISTS res.hex_access;
CREATE TABLE res.hex_access AS
SELECT ca.type, ca.mode, ca.scenario, hc.hex_id,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ca.seconds) / 60)::numeric, 1) AS minutes,
       mode() WITHIN GROUP (ORDER BY ca.facility_id)                                     AS facility_id
FROM svc.cell_access ca
JOIN res.hex_cell hc USING (cell_id)
GROUP BY ca.type, ca.mode, ca.scenario, hc.hex_id;

ALTER TABLE res.hex_access ADD PRIMARY KEY (type, mode, scenario, hex_id);

SELECT meta.log('surface', 'hexagons',      (SELECT count(*) FROM res.hex));
SELECT meta.log('surface', 'hex_side_m',    :hex_m);

COMMIT;
