from fastapi import APIRouter

from app.db import fetch_all
from app.meta import meta
from app.schemas import Dataset, Meta, Scenario
from app.text import DISCLAIMER, TITLE

router = APIRouter(tags=["status"])


@router.get(
    "/meta",
    response_model=Meta,
    summary="Assumptions, settings, data sources and counts",
    description="Everything a client needs to describe the results: what was assumed and why.",
)
def info() -> Meta:
    log = {
        (step, item): float(value)
        for step, item, value in fetch_all(
            "SELECT step, item, value FROM meta.import_log "
            "WHERE step IN ('study_area', 'land', 'config')"
        )
    }
    units = fetch_all("SELECT units FROM ref.study_area")[0][0]
    scenarios = [
        Scenario(scenario=s, applies_to=a, walk_kmh=float(w), drive_factor=float(f), description=d)
        for s, a, w, f, d in fetch_all(
            "SELECT scenario, applies_to, walk_kmh, drive_factor, description "
            "FROM net.scenarios ORDER BY scenario"
        )
    ]
    speeds = {
        h: (float(k) if k is not None else None)
        for h, k in fetch_all(
            "SELECT highway, drive_kmh FROM net.speeds ORDER BY drive_kmh DESC NULLS LAST, highway"
        )
    }
    facilities = dict(
        fetch_all(
            "SELECT type, count(*)::int FROM svc.facilities "
            "WHERE in_study GROUP BY type ORDER BY type"
        )
    )
    datasets = [
        Dataset(name=n, source_url=u, licence=lic, data_date=d)
        for n, u, lic, d in fetch_all(
            "SELECT name, source_url, licence, data_date FROM meta.dataset ORDER BY name"
        )
    ]
    return Meta(
        title=TITLE,
        disclaimer=DISCLAIMER,
        study_area={
            "name": "Greater Banjul",
            "units": units,
            "area_km2": log.get(("study_area", "area_km2"), 0.0),
            "land_area_km2": log.get(("land", "land_area_km2"), 0.0),
        },
        settings={
            k: log[("config", k)]
            for k in ("buffer_m", "cell_m", "access_m")
            if ("config", k) in log
        },
        bands=meta.bands,
        scenarios=scenarios,
        drive_speeds_kmh=speeds,
        facilities=facilities,
        datasets=datasets,
    )
