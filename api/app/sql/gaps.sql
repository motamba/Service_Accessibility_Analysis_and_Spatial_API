-- Gap areas (land beyond the time band), largest number of buildings first.
-- Returns NULL when the combination was not computed (the API answers 404).
SELECT CASE WHEN EXISTS (
           SELECT 1 FROM res.service_areas
           WHERE type = %(type)s AND mode = %(mode)s AND scenario = %(scenario)s AND minutes = %(minutes)s)
       THEN json_build_object(
           'type', 'FeatureCollection',
           'features', COALESCE(
               json_agg(ST_AsGeoJSON(t.*, 'geom', 6, false, 'id')::json ORDER BY t.n_buildings DESC, t.id),
               '[]'::json)
       )::text END
FROM (
    SELECT g.id, g.type, g.mode, g.scenario, g.minutes, g.area_km2, g.n_buildings,
           ST_Transform(
               CASE WHEN %(simplify_m)s > 0
                    THEN ST_SimplifyPreserveTopology(g.geom, %(simplify_m)s)
                    ELSE g.geom END,
               4326) AS geom
    FROM res.gaps g
    WHERE g.type = %(type)s AND g.mode = %(mode)s AND g.scenario = %(scenario)s
      AND g.minutes = %(minutes)s AND g.n_buildings >= %(min_buildings)s
) t;
