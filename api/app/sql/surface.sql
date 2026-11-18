-- Travel time per hexagon for one type/mode/scenario: [hex_id, minutes, facility_id] rows.
-- Hexagons without road access are left out.
SELECT json_agg(json_build_array(hex_id, minutes, facility_id) ORDER BY hex_id)::text
FROM res.hex_access
WHERE type = %(type)s AND mode = %(mode)s AND scenario = %(scenario)s;
