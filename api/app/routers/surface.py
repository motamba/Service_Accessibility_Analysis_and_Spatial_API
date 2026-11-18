import json
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response

from app.db import fetch_value, sql
from app.meta import meta
from app.schemas import FacilityType, GeoJSONResponse, HexCollection, Mode, Surface

router = APIRouter(tags=["surface"])

# The data only changes when the pipeline runs again: let browsers cache for an hour.
CACHE = {"Cache-Control": "public, max-age=3600"}


@router.get(
    "/surface/hexes",
    response_class=GeoJSONResponse,
    responses={200: {"model": HexCollection, "content": {"application/geo+json": {}}}},
    summary="Hexagons of the travel-time surface",
    description=(
        "Hexagons (200 m sides, clipped to land) with the number of buildings in each. "
        "The Feature `id` is the `hex_id` used by `/surface`. Load once, then join the times."
    ),
)
def surface_hexes() -> GeoJSONResponse:
    return GeoJSONResponse(fetch_value(sql("surface_hexes")), headers=CACHE)


@router.get(
    "/surface",
    response_model=Surface,
    summary="Travel time to the nearest facility, per hexagon",
    description=(
        "Median travel time of each hexagon's 50 m analysis cells to the nearest facility, "
        "and the facility most of them are nearest to. Compact rows of "
        "`[hex_id, minutes, facility_id]`; hexagons with no road within 150 m are left out."
    ),
)
def surface(
    type: Annotated[FacilityType, Query(description="Facility type")],
    mode: Annotated[Mode, Query(description="Travel mode")],
    scenario: Annotated[str, Query(description="Speed scenario")] = "base",
) -> Response:
    meta.check_scenario(mode.value, scenario)
    rows = fetch_value(
        sql("surface"), {"type": type.value, "mode": mode.value, "scenario": scenario}
    )
    if rows is None:
        raise HTTPException(404, "No surface computed for this combination")
    body = (
        f'{{"type":{json.dumps(type.value)},"mode":{json.dumps(mode.value)},'
        f'"scenario":{json.dumps(scenario)},"bands":{json.dumps(meta.bands[mode.value])},'
        f'"hexes":{rows}}}'
    )
    return Response(body, media_type="application/json", headers=CACHE)
