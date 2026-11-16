-- Data-quality checks. Runs at the end of every pipeline run.
--   RAISE EXCEPTION -> the pipeline fails (the result would be wrong)
--   RAISE WARNING   -> printed, pipeline continues (worth a look, documented in the README)

DO $$
DECLARE
    n      bigint;
    pct    numeric;
    names  text;
    t      text;
    rec    record;
    diff   double precision;
BEGIN
    -- ---------------------------------------------------------------- errors
    IF NOT (SELECT bool_and(ST_IsValid(geom)) FROM ref.study_area) THEN
        RAISE EXCEPTION 'ref.study_area has an invalid geometry';
    END IF;
    IF NOT (SELECT bool_and(ST_IsValid(geom)) FROM ref.land) THEN
        RAISE EXCEPTION 'ref.land has an invalid geometry';
    END IF;

    SELECT count(*) INTO n FROM net.edges WHERE walk_ok;
    IF n = 0 THEN RAISE EXCEPTION 'No walkable edges in the main network'; END IF;
    SELECT count(*) INTO n FROM net.edges WHERE drive_ok;
    IF n = 0 THEN RAISE EXCEPTION 'No drivable edges in the main network'; END IF;

    FOREACH t IN ARRAY ARRAY['health', 'school'] LOOP
        SELECT count(*) INTO n FROM svc.facilities WHERE type = t AND in_study;
        IF n = 0 THEN RAISE EXCEPTION 'No % facilities in the study area', t; END IF;
    END LOOP;

    SELECT count(*) INTO n
    FROM svc.facilities f
    WHERE (SELECT count(*) FROM svc.facility_nodes fn WHERE fn.facility_id = f.id) <> 2;
    IF n > 0 THEN RAISE EXCEPTION '% facilities are not snapped for both modes', n; END IF;

    SELECT count(*) INTO n FROM ref.buildings;
    IF n = 0 THEN RAISE EXCEPTION 'No buildings loaded'; END IF;

    -- Independent check of the multi-source search: for a fixed sample of 15 nodes per
    -- (type, mode), the cheapest pgr_dijkstraCost from the node to any facility node, on the
    -- FORWARD graph, must equal the stored time (computed on the reversed graph).
    FOR rec IN SELECT DISTINCT type, mode FROM svc.node_access WHERE scenario = 'base' LOOP
        SELECT max(abs(chk.cost - a.seconds)), count(chk.cost) INTO diff, n
        FROM (SELECT node_id, seconds FROM svc.node_access
              WHERE type = rec.type AND mode = rec.mode AND scenario = 'base' AND seconds > 0
              ORDER BY md5(node_id::text) LIMIT 15) a
        CROSS JOIN LATERAL (
            SELECT min(dc.agg_cost) AS cost
            FROM pgr_dijkstraCost(
                    svc.edges_sql(rec.mode, 'base', false),
                    a.node_id,
                    (SELECT array_agg(DISTINCT fn.node_id)
                     FROM svc.facility_nodes fn JOIN svc.facilities f ON f.id = fn.facility_id
                     WHERE f.type = rec.type AND fn.mode = rec.mode),
                    directed => rec.mode = 'drive') dc) chk;
        IF n < 15 OR diff > 0.01 THEN
            RAISE EXCEPTION 'Travel-time cross-check failed for % / %: % of 15 nodes checked, max difference % s',
                rec.type, rec.mode, n, diff;
        END IF;
    END LOOP;

    -- Results: valid geometries, and coverage can only grow with a longer time band.
    SELECT count(*) INTO n FROM res.service_areas WHERE NOT ST_IsValid(geom);
    IF n > 0 THEN RAISE EXCEPTION '% invalid service-area geometries', n; END IF;
    SELECT count(*) INTO n FROM res.gaps WHERE NOT ST_IsValid(geom);
    IF n > 0 THEN RAISE EXCEPTION '% invalid gap geometries', n; END IF;

    SELECT count(*) INTO n
    FROM res.coverage a JOIN res.coverage b USING (type, mode, scenario)
    WHERE a.minutes < b.minutes AND a.buildings_in > b.buildings_in;
    IF n > 0 THEN RAISE EXCEPTION 'Coverage decreases with a longer time band in % cases', n; END IF;

    -- ---------------------------------------------------------------- warnings
    SELECT round((100 - 100 * sum(length_m) FILTER (WHERE walk_ok) / sum(length_m))::numeric, 2) INTO pct FROM net.edges;
    IF pct > 5 THEN
        RAISE WARNING '% %% of road length is outside the main walking network', pct;
    END IF;

    SELECT string_agg(format('%s "%s" (%s, %s m)', f.subtype, COALESCE(f.name, '?'), fn.mode, fn.snap_m), '; '),
           count(*)
      INTO names, n
    FROM svc.facility_nodes fn JOIN svc.facilities f ON f.id = fn.facility_id
    WHERE fn.flagged;
    IF n > 0 THEN
        RAISE WARNING '% facility snaps over 500 m: %', n, names;
    END IF;

    RAISE NOTICE 'All data-quality checks passed.';
END $$;
