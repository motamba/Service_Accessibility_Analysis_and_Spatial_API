-- Travel time from every road node to the nearest facility, for every
-- facility type x mode x applicable scenario.
-- Input : net.edges, net.scenarios, svc.facilities, svc.facility_nodes (+ functions in 40_functions.sql)
-- Output: svc.node_access

BEGIN;

TRUNCATE svc.node_access;

SELECT svc.compute_node_access(t.type, m.mode, s.scenario)
FROM (VALUES ('health'), ('school')) AS t(type)
CROSS JOIN (VALUES ('walk'), ('drive')) AS m(mode)
JOIN net.scenarios s ON s.applies_to IN (m.mode, 'both')
ORDER BY 1;

ANALYZE svc.node_access;

-- Share of network nodes in the study area reached within 60 min, and the median time.
SELECT meta.log('node_access', a.type || '_' || a.mode || '_' || a.scenario || '_median_min',
                round((percentile_cont(0.5) WITHIN GROUP (ORDER BY a.seconds) / 60)::numeric, 1))
FROM svc.node_access a
JOIN net.vertices v ON v.id = a.node_id
JOIN ref.study_area sa ON ST_Intersects(v.geom, sa.geom)
GROUP BY a.type, a.mode, a.scenario;

COMMIT;
