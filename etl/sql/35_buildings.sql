-- Building points (Google Open Buildings v3) inside the study area.
-- Used only to COUNT buildings: in gap areas, and within each travel-time band.
-- Input : ref.buildings_raw (ogr2ogr from the points CSV, already filtered by confidence and bbox)
-- Output: ref.buildings

BEGIN;

DROP TABLE IF EXISTS ref.buildings;
CREATE TABLE ref.buildings AS
SELECT b.id,
       b.area_in_meters::numeric AS area_m2,
       b.confidence::numeric     AS confidence,
       b.full_plus_code          AS plus_code,
       b.geom::geometry(Point, 32628) AS geom
FROM ref.buildings_raw b, ref.study_area sa
WHERE ST_Intersects(b.geom, sa.geom);

ALTER TABLE ref.buildings ADD PRIMARY KEY (id);
CREATE INDEX ON ref.buildings USING gist (geom);
ANALYZE ref.buildings;
DROP TABLE ref.buildings_raw;

SELECT meta.log('buildings', 'in_study_area', (SELECT count(*) FROM ref.buildings));
SELECT meta.log('buildings', 'median_area_m2',
                (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY area_m2)::numeric(10,1) FROM ref.buildings));
SELECT meta.log('buildings', 'on_water',
                (SELECT count(*) FROM ref.buildings b WHERE NOT EXISTS
                    (SELECT 1 FROM ref.land l WHERE ST_Intersects(l.geom, b.geom))));

COMMIT;
