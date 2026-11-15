-- Data-quality checks. Runs at the end of every pipeline run.
--   RAISE EXCEPTION -> the pipeline fails (the result would be wrong)
--   RAISE WARNING   -> printed, pipeline continues (worth a look, documented in the README)

DO $$
DECLARE
    n      bigint;
    pct    numeric;
    names  text;
    t      text;
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
