from typing import Annotated

from fastapi import APIRouter, HTTPException, Query

from app.db import fetch_value, sql
from app.meta import meta
from app.schemas import FacilityType, GapCollection, GeoJSONResponse, Mode

router = APIRouter(tags=["access"])


@router.get(
    "/gaps",
    response_class=GeoJSONResponse,
    responses={
        200: {"model": GapCollection, "content": {"application/geo+json": {}}},
        422: {"description": "Invalid combination of mode, minutes and scenario"},
    },
    summary="Areas beyond a travel time from any facility",
    description=(
        "Land that is NOT within `minutes` of a facility of `type`: one polygon per separate "
        "area (slivers under 0.5 ha are left out), with its area and number of buildings, "
        "largest number of buildings first. Large gaps can be mangroves or undeveloped land; "
        "use `min_buildings` to keep only populated gaps."
    ),
)
def gaps(
    type: Annotated[FacilityType, Query(description="Facility type")],
    mode: Annotated[Mode, Query(description="Travel mode")],
    minutes: Annotated[int, Query(description="Time band in minutes")],
    scenario: Annotated[str, Query(description="Speed scenario")] = "base",
    min_buildings: Annotated[
        int, Query(ge=0, description="Only gaps with at least this many buildings")
    ] = 0,
    simplify_m: Annotated[
        float, Query(ge=0, le=100, description="Simplify outlines by up to this many metres")
    ] = 10,
) -> GeoJSONResponse:
    meta.check_band(mode.value, minutes, scenario)
    body = fetch_value(
        sql("gaps"),
        {
            "type": type.value,
            "mode": mode.value,
            "minutes": minutes,
            "scenario": scenario,
            "min_buildings": min_buildings,
            "simplify_m": simplify_m,
        },
    )
    if body is None:
        raise HTTPException(404, "No results computed for this combination")
    return GeoJSONResponse(body)
