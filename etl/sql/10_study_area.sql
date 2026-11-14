-- Study area = union of the admin-2 units listed in etl/config/study_area.env.
-- Input : ref.admin2 (loaded by ogr2ogr, EPSG:32628)
-- Vars  : :study_adm2 (comma-separated p-codes), :buffer_m (routing buffer in metres)
-- Output: ref.study_units, ref.study_area (geom, geom_buffer)

BEGIN;

DROP TABLE IF EXISTS ref.study_units;
CREATE TABLE ref.study_units AS
SELECT trim(code) AS adm2_pcode
FROM unnest(string_to_array(:'study_adm2', ',')) AS code;

-- Fail loudly if a configured code is missing from the boundary data.
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(u.adm2_pcode, ', ') INTO missing
    FROM ref.study_units u
    LEFT JOIN ref.admin2 a ON a.adm2_pcode = u.adm2_pcode
    WHERE a.adm2_pcode IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Study-area codes not found in ref.admin2: %', missing;
    END IF;
END $$;

DROP TABLE IF EXISTS ref.study_area CASCADE;
CREATE TABLE ref.study_area (
    id          int PRIMARY KEY,
    units       text NOT NULL,
    geom        geometry(MultiPolygon, 32628) NOT NULL,
    geom_buffer geometry(MultiPolygon, 32628) NOT NULL
);

INSERT INTO ref.study_area (id, units, geom, geom_buffer)
SELECT 1,
       string_agg(a.adm2_name, ', ' ORDER BY a.adm2_pcode),
       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(a.geom)), 3)),
       ST_Multi(ST_Buffer(ST_Union(a.geom), :buffer_m))
FROM ref.admin2 a
JOIN ref.study_units u USING (adm2_pcode);

CREATE INDEX ON ref.study_area USING gist (geom);

SELECT meta.log('study_area', 'units',          (SELECT count(*) FROM ref.study_units));
SELECT meta.log('study_area', 'area_km2',        (SELECT round((ST_Area(geom) / 1e6)::numeric, 1) FROM ref.study_area));
SELECT meta.log('study_area', 'buffer_area_km2', (SELECT round((ST_Area(geom_buffer) / 1e6)::numeric, 1) FROM ref.study_area));

COMMIT;
