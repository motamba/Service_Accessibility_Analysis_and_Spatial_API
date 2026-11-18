"""Request enums and response shapes. The GeoJSON itself is built in PostGIS; these models document
it in OpenAPI and are used by the tests to validate real responses."""

from enum import StrEnum

from fastapi.responses import Response
from geojson_pydantic import (
    Feature,
    FeatureCollection,
    LineString,
    MultiLineString,
    MultiPolygon,
    Point,
    Polygon,
)
from pydantic import BaseModel, Field


class FacilityType(StrEnum):
    health = "health"
    school = "school"


class Mode(StrEnum):
    walk = "walk"
    drive = "drive"


class GeoJSONResponse(Response):
    media_type = "application/geo+json"


# ---------------------------------------------------------------- facilities
class FacilityProperties(BaseModel):
    # The facility id is the GeoJSON Feature "id" (RFC 7946), not a property.
    type: FacilityType
    subtype: str = Field(description="hospital, health_centre, clinic, doctors or school")
    name: str | None
    operator: str | None
    source: str = Field(description="osm, or maina2019 (public facility list)")
    source_id: str = Field(description="e.g. way/123456 (OpenStreetMap) or maina2019/42")
    mapped_as: str = Field(description="point or area in the source data")
    in_study: bool = Field(description="inside the study area (false: in the 5 km buffer)")
    snap_walk_m: float = Field(description="distance to the walking network, metres")
    snap_drive_m: float = Field(description="distance to the driving network, metres")


FacilityCollection = FeatureCollection[Feature[Point, FacilityProperties]]


# ---------------------------------------------------------------- service areas
class ServiceAreaProperties(BaseModel):
    type: FacilityType
    mode: Mode
    scenario: str
    minutes: int
    area_km2: float = Field(description="land area within the time band")
    buildings_in: int = Field(description="buildings within the time band")
    buildings_total: int = Field(description="buildings in the study area")
    buildings_pct: float = Field(description="share of buildings within the time band, %")


ServiceAreaCollection = FeatureCollection[Feature[MultiPolygon, ServiceAreaProperties]]


# ---------------------------------------------------------------- health
class Health(BaseModel):
    status: str
    database: bool
    osm_data_date: str | None


# ---------------------------------------------------------------- gaps
class GapProperties(BaseModel):
    # The gap id is the GeoJSON Feature "id".
    type: FacilityType
    mode: Mode
    scenario: str
    minutes: int
    area_km2: float
    n_buildings: int = Field(description="buildings inside this gap area")


GapCollection = FeatureCollection[Feature[Polygon, GapProperties]]


# ---------------------------------------------------------------- nearest
class NearestProperties(BaseModel):
    role: str = Field(description="origin, route or facility")
    snap_m: float | None = Field(None, description="origin: distance to the road network, m")
    mode: Mode | None = None
    scenario: str | None = None
    minutes: float | None = Field(None, description="route: travel time on the road network")
    distance_m: float | None = Field(None, description="route: length on the road network")
    type: FacilityType | None = None
    subtype: str | None = None
    name: str | None = None
    source: str | None = None


NearestCollection = FeatureCollection[
    Feature[Point | LineString | MultiLineString | None, NearestProperties]
]


# ---------------------------------------------------------------- stats
class CoverageRow(BaseModel):
    type: FacilityType
    mode: Mode
    scenario: str
    minutes: int
    buildings_in: int
    buildings_total: int
    pct: float = Field(description="share of buildings within the time band, %")


# ---------------------------------------------------------------- meta
class Dataset(BaseModel):
    name: str
    source_url: str | None
    licence: str | None
    data_date: str | None


class Scenario(BaseModel):
    scenario: str
    applies_to: str
    walk_kmh: float
    drive_factor: float
    description: str | None


class Meta(BaseModel):
    title: str
    disclaimer: str
    study_area: dict[str, str | float]
    settings: dict[str, float] = Field(description="buffer_m, cell_m, access_m")
    bands: dict[str, list[int]] = Field(description="time bands in minutes per mode")
    scenarios: list[Scenario]
    drive_speeds_kmh: dict[str, float | None] = Field(
        description="by OSM highway class; null = walking only"
    )
    facilities: dict[str, int] = Field(description="facilities in the study area, by type")
    datasets: list[Dataset]


# ---------------------------------------------------------------- surface
class HexProperties(BaseModel):
    # The hex_id is the GeoJSON Feature "id".
    n_buildings: int


HexCollection = FeatureCollection[Feature[MultiPolygon, HexProperties]]


class Surface(BaseModel):
    type: FacilityType
    mode: Mode
    scenario: str
    bands: list[int] = Field(description="time bands of this mode, minutes (for the legend)")
    hexes: list[tuple[int, float, int]] = Field(description="[hex_id, minutes, facility_id] rows")
