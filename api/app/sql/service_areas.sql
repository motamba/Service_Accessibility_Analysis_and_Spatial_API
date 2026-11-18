-- One service area (land within the time band) with its building coverage, as GeoJSON.
-- Optional simplification (metres, EPSG:32628) keeps responses small for web maps.
-- Returns NULL when the combination was not computed (the API answers 404).
SELECT CASE WHEN count(*) > 0 THEN json_build_object(
         'type', 'FeatureCollection',
         'features', json_agg(ST_AsGeoJSON(t.*, 'geom', 6)::json)
       )::text END
FROM (
    SELECT sa.type, sa.mode, sa.scenario, sa.minutes, sa.area_km2,
           c.buildings_in, c.buildings_total, c.pct AS buildings_pct,
           ST_Transform(
               CASE WHEN %(simplify_m)s > 0
                    THEN ST_Multi(ST_SimplifyPreserveTopology(sa.geom, %(simplify_m)s))
                    ELSE sa.geom END,
               4326) AS geom
    FROM res.service_areas sa
    JOIN res.coverage c USING (type, mode, scenario, minutes)
    WHERE sa.type = %(type)s AND sa.mode = %(mode)s
      AND sa.scenario = %(scenario)s AND sa.minutes = %(minutes)s
) t;
