-- Hexagon shapes of the travel-time surface (sent once; the times come from surface.sql).
SELECT json_build_object(
         'type', 'FeatureCollection',
         'features', COALESCE(json_agg(ST_AsGeoJSON(t.*, 'geom', 5, false, 'id')::json ORDER BY t.id), '[]'::json)
       )::text
FROM (
    -- geom_web: prepared by the pipeline (WGS 84, shoreline-cut hexagons simplified by 5 m)
    SELECT hex_id AS id, n_buildings, geom_web AS geom
    FROM res.hex
) t;
