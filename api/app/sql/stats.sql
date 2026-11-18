-- Building coverage per facility type, mode, scenario and time band.
SELECT type, mode, scenario, minutes, buildings_in, buildings_total, pct
FROM res.coverage
WHERE (%(type)s::text IS NULL OR type = %(type)s)
  AND (%(mode)s::text IS NULL OR mode = %(mode)s)
  AND (%(scenario)s::text IS NULL OR scenario = %(scenario)s)
ORDER BY type, mode, scenario, minutes;
