-- Facilities as a GeoJSON FeatureCollection (WGS 84).
SELECT json_build_object(
         'type', 'FeatureCollection',
         'features', COALESCE(json_agg(ST_AsGeoJSON(t.*, 'geom', 6, false, 'id')::json ORDER BY t.id), '[]'::json)
       )::text
FROM (
    SELECT f.id, f.type, f.subtype, f.name, f.operator, f.source, f.source_id, f.mapped_as, f.in_study,
           w.snap_m AS snap_walk_m,
           d.snap_m AS snap_drive_m,
           ST_Transform(f.geom, 4326) AS geom
    FROM svc.facilities f
    JOIN svc.facility_nodes w ON w.facility_id = f.id AND w.mode = 'walk'
    JOIN svc.facility_nodes d ON d.facility_id = f.id AND d.mode = 'drive'
    WHERE (%(type)s::text IS NULL OR f.type = %(type)s)
      AND (f.in_study OR %(include_buffer)s)
) t;
