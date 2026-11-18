from typing import Annotated

from fastapi import APIRouter, Query

from app.db import fetch_value, sql
from app.schemas import FacilityCollection, FacilityType, GeoJSONResponse

router = APIRouter(tags=["facilities"])


@router.get(
    "/facilities",
    response_class=GeoJSONResponse,
    responses={200: {"model": FacilityCollection, "content": {"application/geo+json": {}}}},
    summary="Health facilities and schools",
    description=(
        "Facilities used in the analysis, as GeoJSON points (WGS 84). Health facilities combine "
        "OpenStreetMap with public facilities from Maina et al. (2019); schools come from "
        "OpenStreetMap."
    ),
)
def facilities(
    type: Annotated[FacilityType | None, Query(description="Facility type; omit for both")] = None,
    include_buffer: Annotated[
        bool,
        Query(description="Also return facilities in the 5 km buffer around the study area"),
    ] = False,
) -> GeoJSONResponse:
    body = fetch_value(
        sql("facilities"),
        {"type": type.value if type else None, "include_buffer": include_buffer},
    )
    return GeoJSONResponse(body)
