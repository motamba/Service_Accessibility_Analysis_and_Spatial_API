-- Water areas from OSM, and the land part of the study area (base layer for gaps).
-- Input : ref.water_raw (ogr2ogr "multipolygons" layer of the water-filtered extract)
-- Output: ref.water, ref.land

BEGIN;

-- OSM polygons can be invalid (self-intersections), so repair them before any spatial test.
DROP TABLE IF EXISTS ref.water;
CREATE TABLE ref.water AS
WITH valid AS (
    SELECT id,
           COALESCE(osm_id, osm_way_id) AS osm_id,
           name,
           ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, 32628) AS geom
    FROM ref.water_raw
    -- osmium tags-filter also passes on the member ways of matching relations (e.g. mangrove
    -- islands inside a river multipolygon), so keep only features that are water themselves.
    WHERE "natural" = 'water'
       OR other_tags ~ '"water"=>'
       OR other_tags ~ '"waterway"=>"riverbank"'
)
SELECT v.*
FROM valid v, ref.study_area sa
WHERE NOT ST_IsEmpty(v.geom)
  AND ST_Intersects(v.geom, sa.geom_buffer);

ALTER TABLE ref.water ADD PRIMARY KEY (id);
CREATE INDEX ON ref.water USING gist (geom);
DROP TABLE ref.water_raw;

DROP TABLE IF EXISTS ref.land;
CREATE TABLE ref.land AS
SELECT 1 AS id,
       ST_Multi(ST_CollectionExtract(
           ST_Difference(
               sa.geom,
               COALESCE((SELECT ST_Union(w.geom) FROM ref.water w WHERE ST_Intersects(w.geom, sa.geom)),
                        ST_GeomFromText('POLYGON EMPTY', 32628))),
           3))::geometry(MultiPolygon, 32628) AS geom
FROM ref.study_area sa;

CREATE INDEX ON ref.land USING gist (geom);

SELECT meta.log('land', 'water_polygons', (SELECT count(*) FROM ref.water));
SELECT meta.log('land', 'land_area_km2',  (SELECT round((ST_Area(geom) / 1e6)::numeric, 1) FROM ref.land));

COMMIT;
