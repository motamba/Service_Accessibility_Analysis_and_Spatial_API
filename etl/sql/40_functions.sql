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
-- Multi-source shortest paths with a virtual SUPER-SOURCE (node -1):
--   * a zero-cost edge goes from -1 to every facility node (one-way: -1 -> facility);
--   * ONE pgr_drivingDistance from -1 then gives every node its time to the NEAREST facility,
--     in a single Dijkstra run, however many facilities there are;
--   * the facility is found by following the search tree (pred) back to the node just below -1.
-- Nodes not reached within p_max_seconds get no row (= further than the limit).
--
-- Why not pgRouting's own multi-root mode? With equicost => true, pgRouting 3.8.0 returned
-- non-optimal times for some nodes (e.g. 1174.96 s instead of 1161.68 s, caught by the
-- cross-check in 90_checks.sql); with equicost => false it returns one full tree per facility,
-- which is exact but far too slow (100+ trees over the whole network).
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

    -- Search tree from the super-source.
    DROP TABLE IF EXISTS pg_temp.tree;
    CREATE TEMP TABLE tree ON COMMIT DROP AS
    SELECT dd.node, dd.pred, dd.agg_cost
    FROM pgr_drivingDistance(
            format('%s UNION ALL
                    SELECT -row_number() OVER () AS id, -1::bigint AS source, s AS target,
                           0::float8 AS cost, -1::float8 AS reverse_cost
                    FROM unnest(%L::bigint[]) AS s',
                   svc.edges_sql(p_mode, p_scenario, p_reversed => p_mode = 'drive'), starts),
            -1,
            p_max_seconds,
            directed => true) dd
    WHERE dd.node <> -1;          -- the super-source's own row (its own parent) would loop forever
    CREATE INDEX ON tree (pred);
    ANALYZE tree;                 -- without statistics the recursive walk gets a very slow plan

    DELETE FROM svc.node_access
    WHERE type = p_type AND mode = p_mode AND scenario = p_scenario;

    -- Walk the tree top-down: facility nodes (pred = -1) are roots and pass their id down.
    INSERT INTO svc.node_access (type, mode, scenario, node_id, facility_id, seconds)
    WITH RECURSIVE down AS (
        SELECT t.node, t.node AS root, t.agg_cost FROM tree t WHERE t.pred = -1
        UNION ALL
        SELECT t.node, d.root, t.agg_cost FROM tree t JOIN down d ON t.pred = d.node
    )
    SELECT p_type, p_mode, p_scenario, d.node, fac.facility_id, d.agg_cost
    FROM down d
    -- Several facilities can snap to the same node; the lowest id represents them.
    CROSS JOIN LATERAL (
        SELECT fn.facility_id FROM svc.facility_nodes fn JOIN svc.facilities f ON f.id = fn.facility_id
        WHERE fn.node_id = d.root AND fn.mode = p_mode AND f.type = p_type
        ORDER BY fn.facility_id LIMIT 1) fac;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- ------------------------------------------------------------------ travel time per grid cell
CREATE TABLE IF NOT EXISTS svc.cell_access (
    type        text    NOT NULL,
    mode        text    NOT NULL,
    scenario    text    NOT NULL,
    cell_id     int     NOT NULL,
    facility_id int     NOT NULL,
    seconds     double precision NOT NULL,
    PRIMARY KEY (type, mode, scenario, cell_id)
);

-- Time from a cell to its nearest facility = best over the cell's nearby edges (svc.cell_edges)
-- of: the time along the edge from the closest point to one end, plus that end's node time.
-- Going towards the source end means travelling target->source along the edge, so for driving
-- that end is only usable if the edge allows that direction (one-way streets).
-- The walk from the cell centre to the road (<= 150 m) is not added to the time.
CREATE OR REPLACE FUNCTION svc.compute_cell_access(p_type text, p_mode text, p_scenario text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    s net.scenarios%ROWTYPE;
    n bigint;
BEGIN
    SELECT * INTO s FROM net.scenarios WHERE scenario = p_scenario;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown scenario: %', p_scenario; END IF;

    DELETE FROM svc.cell_access WHERE type = p_type AND mode = p_mode AND scenario = p_scenario;

    INSERT INTO svc.cell_access (type, mode, scenario, cell_id, facility_id, seconds)
    SELECT DISTINCT ON (cell_id) p_type, p_mode, p_scenario, cell_id, facility_id, seconds
    FROM (
        SELECT ce.cell_id, a.facility_id, a.seconds + along.sec AS seconds
        FROM svc.cell_edges ce
        JOIN net.edges e ON e.id = ce.edge_id
        CROSS JOIN LATERAL (
            SELECT CASE WHEN p_mode = 'walk' THEN e.length_m / (s.walk_kmh / 3.6)
                        ELSE e.length_m / (e.drive_kmh * s.drive_factor / 3.6) END AS full_sec
        ) c
        -- the two ways out of the edge: to the source end, or to the target end
        CROSS JOIN LATERAL (VALUES
            (e.source, ce.frac       * c.full_sec, p_mode = 'walk' OR e.bwd_ok),
            (e.target, (1 - ce.frac) * c.full_sec, p_mode = 'walk' OR e.fwd_ok)
        ) AS along(node_id, sec, allowed)
        JOIN svc.node_access a
          ON a.node_id = along.node_id AND a.type = p_type AND a.mode = p_mode AND a.scenario = p_scenario
        WHERE ce.mode = p_mode AND along.allowed
    ) x
    ORDER BY cell_id, seconds, facility_id;

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
