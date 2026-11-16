-- Routing functions. They only read net.edges / net.scenarios / svc.facility_nodes, so the
-- same functions run on the real network and on the synthetic test network (api/tests).

-- ------------------------------------------------------------------ edge query for pgRouting
-- Returns the SQL text pgRouting needs (id, source, target, cost, reverse_cost), with costs in
-- SECONDS for the given mode and scenario. Costs are computed here, not stored, so a new speed
-- scenario needs no re-import.
--   walk  : undirected; every walkable edge in the main walking network
--   drive : directed; cost -1 means "not allowed in this direction" (one-way streets)
--   p_reversed = true swaps cost and reverse_cost. Searching outward from facilities on the
--   reversed graph gives the time FROM each node TO the facility, which is the direction a
--   person travels.
CREATE OR REPLACE FUNCTION svc.edges_sql(p_mode text, p_scenario text, p_reversed boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    s       net.scenarios%ROWTYPE;
    fwd     text;
    bwd     text;
BEGIN
    SELECT * INTO s FROM net.scenarios WHERE scenario = p_scenario;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown scenario: %', p_scenario;
    END IF;

    IF p_mode = 'walk' THEN
        fwd := format('length_m / (%s / 3.6)', s.walk_kmh);
        RETURN format('SELECT id, source, target, %1$s AS cost, %1$s AS reverse_cost
                       FROM net.edges WHERE walk_ok', fwd);
    ELSIF p_mode = 'drive' THEN
        fwd := format('CASE WHEN fwd_ok THEN length_m / (drive_kmh * %s / 3.6) ELSE -1 END', s.drive_factor);
        bwd := format('CASE WHEN bwd_ok THEN length_m / (drive_kmh * %s / 3.6) ELSE -1 END', s.drive_factor);
        IF p_reversed THEN
            RETURN format('SELECT id, source, target, %s AS cost, %s AS reverse_cost
                           FROM net.edges WHERE drive_ok', bwd, fwd);
        END IF;
        RETURN format('SELECT id, source, target, %s AS cost, %s AS reverse_cost
                       FROM net.edges WHERE drive_ok', fwd, bwd);
    END IF;
    RAISE EXCEPTION 'Unknown mode: % (expected walk or drive)', p_mode;
END $$;

-- ------------------------------------------------------------------ results table
CREATE TABLE IF NOT EXISTS svc.node_access (
    type        text    NOT NULL,
    mode        text    NOT NULL,
    scenario    text    NOT NULL,
    node_id     bigint  NOT NULL,
    facility_id int     NOT NULL,
    seconds     double precision NOT NULL,
    PRIMARY KEY (type, mode, scenario, node_id)
);

-- ------------------------------------------------------------------ nearest facility per node
-- One pgr_drivingDistance call per (type, mode, scenario), with all facility nodes as roots.
-- Each root's shortest-path tree is returned (equicost => false) and the cheapest root per node
-- is kept with DISTINCT ON. Nodes not reached within p_max_seconds get no row.
--
-- Why not equicost => true (which does this inside pgRouting)? On this network pgRouting 3.8.0
-- returned non-optimal times for some nodes with equicost (e.g. 1174.96 s instead of 1161.68 s,
-- found by the cross-check in 90_checks.sql), so the minimum is taken explicitly here.
CREATE OR REPLACE FUNCTION svc.compute_node_access(p_type text, p_mode text, p_scenario text,
                                                   p_max_seconds double precision DEFAULT 3600)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    starts bigint[];
    n      bigint;
BEGIN
    SELECT array_agg(DISTINCT fn.node_id) INTO starts
    FROM svc.facility_nodes fn JOIN svc.facilities f ON f.id = fn.facility_id
    WHERE f.type = p_type AND fn.mode = p_mode;

    IF starts IS NULL THEN
        RAISE EXCEPTION 'No % facilities snapped for mode %', p_type, p_mode;
    END IF;

    DELETE FROM svc.node_access
    WHERE type = p_type AND mode = p_mode AND scenario = p_scenario;

    INSERT INTO svc.node_access (type, mode, scenario, node_id, facility_id, seconds)
    SELECT p_type, p_mode, p_scenario, dd.node, fac.facility_id, dd.agg_cost
    FROM (
        SELECT DISTINCT ON (node) node, start_vid, agg_cost
        FROM pgr_drivingDistance(
                svc.edges_sql(p_mode, p_scenario, p_reversed => p_mode = 'drive'),
                starts,
                p_max_seconds,
                directed => p_mode = 'drive',
                equicost => false)
        ORDER BY node, agg_cost, start_vid
    ) dd
    -- Several facilities can snap to the same node; the lowest id represents them.
    CROSS JOIN LATERAL (
        SELECT fn.facility_id FROM svc.facility_nodes fn JOIN svc.facilities f ON f.id = fn.facility_id
        WHERE fn.node_id = dd.start_vid AND fn.mode = p_mode AND f.type = p_type
        ORDER BY fn.facility_id LIMIT 1) fac;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
