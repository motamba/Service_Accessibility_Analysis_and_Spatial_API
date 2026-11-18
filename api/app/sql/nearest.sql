-- Nearest facility from a point: snap to the nearest junction of the main network for the mode,
-- look up its pre-computed time to the nearest facility (svc.node_access), and draw the route
-- with pgr_dijkstra on the forward graph.
-- Returns: inside (point in study area), snap_m, body (GeoJSON, NULL if no facility reached).
WITH p AS (
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326), 32628) AS g
),
snap AS (
    SELECT v.id AS node_id, v.geom, ST_Distance(v.geom, p.g) AS snap_m
    FROM p
    CROSS JOIN LATERAL (
        SELECT id, geom FROM net.vertices
        WHERE CASE WHEN %(mode)s = 'walk' THEN in_main_walk ELSE in_main_drive END
        ORDER BY geom <-> p.g
        LIMIT 1) v
),
acc AS (
    SELECT a.facility_id, a.seconds
    FROM svc.node_access a JOIN snap s ON s.node_id = a.node_id
    WHERE a.type = %(type)s AND a.mode = %(mode)s AND a.scenario = %(scenario)s
),
fac AS (
    SELECT f.id, f.type, f.subtype, f.name, f.source, f.geom, fn.node_id AS fac_node
    FROM acc
    JOIN svc.facilities f ON f.id = acc.facility_id
    JOIN svc.facility_nodes fn ON fn.facility_id = f.id AND fn.mode = %(mode)s
),
-- The route is searched only among roads within 2 km of the box around origin and facility,
-- which is much faster than the whole network; if no route is found there (rare detours), the
-- whole network is used. The travel TIME always comes from svc.node_access (exact).
area AS (
    SELECT ST_Expand(ST_Envelope(ST_Collect(snap.geom, v.geom)), 2000) AS box
    FROM snap, fac JOIN net.vertices v ON v.id = fac.fac_node
),
route_local AS (
    SELECT ST_LineMerge(ST_Collect(e.geom ORDER BY d.seq)) AS geom,
           sum(e.length_m) AS length_m,
           count(*) AS n
    FROM snap, fac, area,
         pgr_dijkstra(
             format('%%s AND geom && %%L::geometry', svc.edges_sql(%(mode)s, %(scenario)s, false), area.box),
             snap.node_id, fac.fac_node, directed => %(mode)s = 'drive') d
    JOIN net.edges e ON e.id = d.edge
),
route AS (
    SELECT geom, length_m FROM route_local
    WHERE n > 0 OR (SELECT seconds FROM acc) = 0
    UNION ALL
    SELECT ST_LineMerge(ST_Collect(e.geom ORDER BY d.seq)), sum(e.length_m)
    FROM snap, fac,
         pgr_dijkstra(svc.edges_sql(%(mode)s, %(scenario)s, false), snap.node_id, fac.fac_node,
                      directed => %(mode)s = 'drive') d
    JOIN net.edges e ON e.id = d.edge
    -- WHERE skips the full search when it is not needed; HAVING drops the empty row an
    -- aggregate would otherwise still return.
    WHERE (SELECT n FROM route_local) = 0 AND (SELECT seconds FROM acc) > 0
    HAVING (SELECT n FROM route_local) = 0 AND (SELECT seconds FROM acc) > 0
)
SELECT
    EXISTS (SELECT 1 FROM ref.study_area sa, p WHERE ST_Intersects(sa.geom, p.g)) AS inside,
    (SELECT round(snap_m::numeric, 1) FROM snap)                                  AS snap_m,
    (SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', json_build_array(
            json_build_object(
                'type', 'Feature',
                'geometry', ST_AsGeoJSON(ST_Transform(p.g, 4326), 6)::json,
                'properties', json_build_object(
                    'role', 'origin',
                    'snap_m', round(snap.snap_m::numeric, 1))),
            json_build_object(
                'type', 'Feature',
                'geometry', ST_AsGeoJSON(ST_Transform(route.geom, 4326), 6)::json,
                'properties', json_build_object(
                    'role', 'route',
                    'mode', %(mode)s,
                    'scenario', %(scenario)s,
                    'minutes', round((acc.seconds / 60)::numeric, 1),
                    'distance_m', COALESCE(round(route.length_m::numeric), 0))),
            json_build_object(
                'type', 'Feature',
                'id', fac.id,
                'geometry', ST_AsGeoJSON(ST_Transform(fac.geom, 4326), 6)::json,
                'properties', json_build_object(
                    'role', 'facility',
                    'type', fac.type,
                    'subtype', fac.subtype,
                    'name', fac.name,
                    'source', fac.source))))::text
     FROM p, snap, acc, fac, route)                                               AS body;
