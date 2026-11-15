-- Health facilities and schools, merged into one point per facility and snapped to the
-- routing network.
-- Input : ref.fac_points_raw, ref.fac_polys_raw  (OSM via ogr2ogr, EPSG:32628)
--         ref.maina_raw                          (public health facilities, Maina et al. 2019)
--         net.vertices
-- Output: svc.facilities, svc.facility_nodes
--
-- Definitions (also in the README):
--   health : OSM amenity = hospital | clinic | doctors, or healthcare = hospital | clinic | centre | doctor
--            (pharmacies, dentists and other specialists are not counted)
--            + public facilities from Maina et al. (2019) with no OSM health facility within 200 m
--   school : OSM amenity = school   (kindergartens, colleges and universities are not counted)

BEGIN;

-- ------------------------------------------------------------------ OSM candidates
CREATE TEMP TABLE candidates ON COMMIT DROP AS
WITH raw AS (
    SELECT 'node'::text AS osm_type, osm_id::text AS source_id, name, amenity, healthcare, operator,
           geom AS geom_src, geom AS pt, false AS is_area
    FROM ref.fac_points_raw
    UNION ALL
    SELECT CASE WHEN osm_id IS NOT NULL THEN 'relation' ELSE 'way' END,
           COALESCE(osm_id, osm_way_id)::text, name, amenity, healthcare, operator,
           ST_MakeValid(geom), ST_PointOnSurface(ST_MakeValid(geom)), true
    FROM ref.fac_polys_raw
)
SELECT 'osm'::text AS source,
       r.osm_type || '/' || r.source_id AS source_id,
       r.name, r.operator, r.geom_src, r.pt, r.is_area,
       CASE WHEN r.amenity IN ('hospital', 'clinic', 'doctors')
              OR r.healthcare IN ('hospital', 'clinic', 'centre', 'doctor') THEN 'health'
            WHEN r.amenity = 'school' THEN 'school'
       END AS type,
       CASE WHEN r.amenity = 'hospital' OR r.healthcare = 'hospital'                    THEN 'hospital'
            WHEN r.amenity = 'clinic' OR r.healthcare IN ('clinic', 'centre')          THEN 'clinic'
            WHEN r.amenity = 'doctors' OR r.healthcare = 'doctor'                      THEN 'doctors'
            WHEN r.amenity = 'school'                                                  THEN 'school'
       END AS subtype
FROM raw r;

-- osmium also passes on member ways of matching relations (often plain buildings): drop
-- anything that is not itself a facility, and anything outside the routing buffer.
DELETE FROM candidates c
USING ref.study_area sa
WHERE c.type IS NULL OR NOT ST_Intersects(c.pt, sa.geom_buffer);

-- ------------------------------------------------------------------ OSM de-duplication
-- The same facility is often mapped twice: as an area and as a point inside it (or right
-- next to it). Keep the area; drop points of the same type within 50 m of it.
DELETE FROM candidates p
USING candidates a
WHERE NOT p.is_area AND a.is_area
  AND p.type = a.type
  AND ST_DWithin(p.geom_src, a.geom_src, 50);

-- Areas nested in a larger area of the same type (e.g. a ward inside a hospital campus).
DELETE FROM candidates small
USING candidates big
WHERE small.is_area AND big.is_area
  AND small.type = big.type
  AND small.source_id <> big.source_id
  AND ST_Area(small.geom_src) < ST_Area(big.geom_src)
  AND ST_Within(small.pt, big.geom_src);

-- ------------------------------------------------------------------ public health facilities
-- Maina et al. (2019): public-sector facilities (MoH, NGO, CBO). Their coordinates are
-- geocoded (Google Earth, gazetteers) and can be 0.5-2 km off, so a Maina facility is matched
-- to an OSM facility by NAME, not by distance alone, and then dropped in favour of the OSM point.
INSERT INTO candidates (source, source_id, name, operator, geom_src, pt, is_area, type, subtype)
SELECT 'maina2019',
       'maina2019/' || m.id,
       m."facility n",
       m.ownership,
       m.geom, m.geom, false,
       'health',
       CASE WHEN m."facility t" ILIKE '%hospital%'      THEN 'hospital'
            WHEN m."facility t" ILIKE '%health centre%' THEN 'health_centre'
            ELSE 'clinic'
       END
FROM ref.maina_raw m, ref.study_area sa
WHERE ST_Intersects(m.geom, sa.geom_buffer);

-- Name key: lower case, without generic words, so "Fajikunda Major Health Centre" and
-- "fagikunda major hospital" both reduce to a near-identical key.
CREATE OR REPLACE FUNCTION pg_temp.name_key(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT trim(regexp_replace(regexp_replace(lower(coalesce(t, '')),
           '\m(minor|major|health|heath|centre|center|hospital|clinic|general|teaching|the)\M', '', 'g'),
           '\s+', ' ', 'g'))
$$;

-- Candidate pairs: within 2.5 km and similar name keys (pg_trgm similarity >= 0.5).
-- Ranked on each side by full-name similarity, then distance; only MUTUAL best pairs match,
-- so one OSM facility never absorbs two different Maina facilities (e.g. "Serekunda General
-- Hospital" vs "Serekunda Minor Health Centre").
CREATE TEMP TABLE maina_matched ON COMMIT DROP AS
WITH pairs AS (
    SELECT m.source_id AS maina_id, m.name AS maina_name,
           o.source_id AS osm_id,   o.name AS osm_name,
           round(ST_Distance(m.pt, o.geom_src)) AS dist_m,
           similarity(lower(m.name), lower(o.name)) AS full_sim
    FROM candidates m
    JOIN candidates o
      ON o.source = 'osm' AND o.type = 'health'
     AND ST_DWithin(m.pt, o.geom_src, 2500)
     AND similarity(pg_temp.name_key(m.name), pg_temp.name_key(o.name)) >= 0.5
    WHERE m.source = 'maina2019'
), ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY maina_id ORDER BY full_sim DESC, dist_m) AS rank_m,
           row_number() OVER (PARTITION BY osm_id   ORDER BY full_sim DESC, dist_m) AS rank_o
    FROM pairs
)
SELECT maina_id, maina_name, osm_id, osm_name, dist_m FROM ranked WHERE rank_m = 1 AND rank_o = 1;

DELETE FROM candidates c USING maina_matched mm WHERE c.source_id = mm.maina_id;

-- Kept for transparency (README / data-quality section).
DROP TABLE IF EXISTS svc.facility_matches;
CREATE TABLE svc.facility_matches AS SELECT * FROM maina_matched;

-- ------------------------------------------------------------------ facilities
DROP TABLE IF EXISTS svc.facilities CASCADE;
CREATE TABLE svc.facilities (
    id          serial PRIMARY KEY,
    type        text    NOT NULL CHECK (type IN ('health', 'school')),
    subtype     text    NOT NULL,
    name        text,
    operator    text,
    source      text    NOT NULL CHECK (source IN ('osm', 'maina2019')),
    source_id   text    NOT NULL UNIQUE,    -- e.g. way/123456 or maina2019/42
    mapped_as   text    NOT NULL CHECK (mapped_as IN ('point', 'area')),
    in_study    boolean NOT NULL,           -- inside the study area (vs. only in the 5 km buffer)
    geom        geometry(Point, 32628) NOT NULL
);

INSERT INTO svc.facilities (type, subtype, name, operator, source, source_id, mapped_as, in_study, geom)
SELECT c.type, c.subtype, NULLIF(trim(c.name), ''), c.operator, c.source, c.source_id,
       CASE WHEN c.is_area THEN 'area' ELSE 'point' END,
       ST_Intersects(c.pt, sa.geom),
       c.pt
FROM candidates c, ref.study_area sa
ORDER BY c.type, c.subtype, c.name, c.source_id;

CREATE INDEX ON svc.facilities USING gist (geom);
CREATE INDEX ON svc.facilities (type);

-- ------------------------------------------------------------------ snapping
-- Each facility snaps to the nearest vertex of the main network, separately for each mode
-- (the nearest drivable junction can differ from the nearest walkable one).
DROP TABLE IF EXISTS svc.facility_nodes CASCADE;
CREATE TABLE svc.facility_nodes (
    facility_id int    NOT NULL REFERENCES svc.facilities (id),
    mode        text   NOT NULL CHECK (mode IN ('walk', 'drive')),
    node_id     bigint NOT NULL REFERENCES net.vertices (id),
    snap_m      numeric NOT NULL,
    flagged     boolean NOT NULL,          -- snapped more than 500 m away: check the data
    PRIMARY KEY (facility_id, mode)
);

INSERT INTO svc.facility_nodes (facility_id, mode, node_id, snap_m, flagged)
SELECT f.id, 'walk', v.id, round(v.d::numeric, 1), v.d > 500
FROM svc.facilities f
CROSS JOIN LATERAL (
    SELECT id, geom <-> f.geom AS d FROM net.vertices WHERE in_main_walk
    ORDER BY geom <-> f.geom LIMIT 1) v;

INSERT INTO svc.facility_nodes (facility_id, mode, node_id, snap_m, flagged)
SELECT f.id, 'drive', v.id, round(v.d::numeric, 1), v.d > 500
FROM svc.facilities f
CROSS JOIN LATERAL (
    SELECT id, geom <-> f.geom AS d FROM net.vertices WHERE in_main_drive
    ORDER BY geom <-> f.geom LIMIT 1) v;

CREATE INDEX ON svc.facility_nodes (node_id);

-- Facilities in the buffer (outside the study area) with no road within 1 km cannot serve the
-- study area, e.g. Essau on the north bank of the river (ferries are excluded). Drop them.
CREATE TEMP TABLE unreachable ON COMMIT DROP AS
SELECT DISTINCT f.id, f.name FROM svc.facilities f JOIN svc.facility_nodes fn ON fn.facility_id = f.id
WHERE NOT f.in_study AND fn.snap_m > 1000;
DELETE FROM svc.facility_nodes WHERE facility_id IN (SELECT id FROM unreachable);
DELETE FROM svc.facilities     WHERE id          IN (SELECT id FROM unreachable);
SELECT meta.log('facilities', 'dropped_buffer_unreachable', (SELECT count(*) FROM unreachable));

-- ------------------------------------------------------------------ log
SELECT meta.log('facilities', type || '_' || subtype || '_in_study', count(*))
FROM svc.facilities WHERE in_study GROUP BY type, subtype;
SELECT meta.log('facilities', type || '_total_in_buffer', count(*))
FROM svc.facilities GROUP BY type;
SELECT meta.log('facilities', 'health_from_' || source || '_in_study', count(*))
FROM svc.facilities WHERE type = 'health' AND in_study GROUP BY source;
SELECT meta.log('facilities', 'maina2019_matched_to_osm', (SELECT count(*) FROM maina_matched));
SELECT meta.log('facilities', type || '_unnamed_pct', round(100.0 * count(*) FILTER (WHERE name IS NULL) / count(*), 1))
FROM svc.facilities GROUP BY type;
SELECT meta.log('snapping', mode || '_median_m', percentile_cont(0.5) WITHIN GROUP (ORDER BY snap_m)::numeric(10,1))
FROM svc.facility_nodes GROUP BY mode;
SELECT meta.log('snapping', mode || '_max_m', max(snap_m)) FROM svc.facility_nodes GROUP BY mode;
SELECT meta.log('snapping', mode || '_flagged_over_500m', count(*) FILTER (WHERE flagged))
FROM svc.facility_nodes GROUP BY mode;

COMMIT;
