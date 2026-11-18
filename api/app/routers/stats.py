from typing import Annotated

from fastapi import APIRouter, Query

from app.db import fetch_all, sql
from app.schemas import CoverageRow, FacilityType, Mode

router = APIRouter(tags=["access"])


@router.get(
    "/stats",
    response_model=list[CoverageRow],
    summary="Share of buildings within each travel time",
    description=(
        "Building coverage for every facility type, mode, scenario and time band. Filter with "
        "any of the parameters; omit them all for the full table."
    ),
)
def stats(
    type: Annotated[FacilityType | None, Query(description="Facility type")] = None,
    mode: Annotated[Mode | None, Query(description="Travel mode")] = None,
    scenario: Annotated[str | None, Query(description="Speed scenario")] = None,
) -> list[CoverageRow]:
    rows = fetch_all(
        sql("stats"),
        {
            "type": type.value if type else None,
            "mode": mode.value if mode else None,
            "scenario": scenario,
        },
    )
    fields = CoverageRow.model_fields.keys()
    return [CoverageRow(**dict(zip(fields, row, strict=True))) for row in rows]
