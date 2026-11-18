from typing import Annotated

from fastapi import APIRouter, HTTPException, Query

from app.db import fetch_value, sql
from app.meta import meta
from app.schemas import FacilityType, GeoJSONResponse, Mode, ServiceAreaCollection

router = APIRouter(tags=["access"])


@router.get(
    "/service-areas",
    response_class=GeoJSONResponse,
    responses={
        200: {"model": ServiceAreaCollection, "content": {"application/geo+json": {}}},
        422: {"description": "Invalid combination of mode, minutes and scenario"},
    },
    summary="Area within a travel time of the nearest facility",
    description=(
        "Land within `minutes` of the nearest facility of `type`, on foot or by car, with the "
        "number and share of buildings inside. Time bands: walk 15/30/60, drive 5/10/15 min. "
        "Scenarios: base, walk_slow, walk_fast (walking only), drive_congested (driving only)."
    ),
)
def service_areas(
    type: Annotated[FacilityType, Query(description="Facility type")],
    mode: Annotated[Mode, Query(description="Travel mode")],
    minutes: Annotated[int, Query(description="Time band in minutes")],
    scenario: Annotated[str, Query(description="Speed scenario")] = "base",
    simplify_m: Annotated[
        float, Query(ge=0, le=100, description="Simplify outlines by up to this many metres")
    ] = 10,
) -> GeoJSONResponse:
    meta.check_band(mode.value, minutes, scenario)
    body = fetch_value(
        sql("service_areas"),
        {
            "type": type.value,
            "mode": mode.value,
            "minutes": minutes,
            "scenario": scenario,
            "simplify_m": simplify_m,
        },
    )
    if body is None:
        raise HTTPException(404, "No service area computed for this combination")
    return GeoJSONResponse(body)
