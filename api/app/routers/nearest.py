from typing import Annotated

from fastapi import APIRouter, HTTPException, Query

from app.db import pool, sql
from app.meta import meta
from app.schemas import FacilityType, GeoJSONResponse, Mode, NearestCollection

router = APIRouter(tags=["access"])

# Points further than this from the road network are not answered (e.g. in the mangroves).
MAX_SNAP_M = 1000


@router.get(
    "/nearest",
    response_class=GeoJSONResponse,
    responses={
        200: {"model": NearestCollection, "content": {"application/geo+json": {}}},
        404: {"description": "No road nearby, or no facility within 60 minutes"},
        422: {"description": "Point outside the study area, or invalid parameters"},
    },
    summary="Nearest facility from a point, with travel time and route",
    description=(
        "Snaps the point to the nearest junction of the road network for the mode and returns "
        "three features: the `origin` (with `snap_m`, its distance to the road), the `route` "
        "(travel time in `minutes` and length) and the `facility`. The walk from the point to "
        "the road is not included in the time. The route geometry is null when the point "
        "snaps to the facility's own junction (0 minutes)."
    ),
)
def nearest(
    lat: Annotated[float, Query(ge=-90, le=90, description="Latitude (WGS 84)")],
    lon: Annotated[float, Query(ge=-180, le=180, description="Longitude (WGS 84)")],
    type: Annotated[FacilityType, Query(description="Facility type")],
    mode: Annotated[Mode, Query(description="Travel mode")] = Mode.walk,
    scenario: Annotated[str, Query(description="Speed scenario")] = "base",
) -> GeoJSONResponse:
    meta.check_scenario(mode.value, scenario)
    params = {"lat": lat, "lon": lon, "type": type.value, "mode": mode.value, "scenario": scenario}
    with pool.connection() as conn:
        inside, snap_m, body = conn.execute(sql("nearest"), params).fetchone()

    if not inside:
        raise HTTPException(422, "The point is outside the study area (Greater Banjul)")
    if snap_m is None or snap_m > MAX_SNAP_M:
        raise HTTPException(404, f"No road within {MAX_SNAP_M} m of this point")
    if body is None:
        raise HTTPException(404, f"No {type.value} facility within 60 minutes by {mode.value}")
    return GeoJSONResponse(body)
