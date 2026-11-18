"""API tests against the database built by the pipeline (read-only).

Skipped when that database is not reachable or the pipeline has not run yet.
Every GeoJSON response is validated against the models documented in OpenAPI.
"""

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.schemas import (
    CoverageRow,
    FacilityCollection,
    GapCollection,
    HexCollection,
    Meta,
    NearestCollection,
    ServiceAreaCollection,
    Surface,
)

# Generous bounding box around Greater Banjul (lon/lat)
LON_MIN, LON_MAX, LAT_MIN, LAT_MAX = -16.90, -16.50, 13.25, 13.55


def _pipeline_ready() -> bool:
    try:
        with psycopg.connect(settings.database_url, connect_timeout=3) as conn:
            return conn.execute("SELECT to_regclass('res.coverage') IS NOT NULL").fetchone()[0]
    except psycopg.OperationalError:
        return False


pytestmark = pytest.mark.skipif(
    not _pipeline_ready(), reason="pipeline database not available (run `docker compose up` first)"
)


@pytest.fixture(scope="module")
def client():
    from app.main import app

    with TestClient(app) as c:  # runs start-up: pool + metadata
        yield c


# ---------------------------------------------------------------- status and docs
def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["database"] is True
    assert body["osm_data_date"]


def test_openapi_lists_endpoints(client):
    paths = client.get("/openapi.json").json()["paths"]
    assert {
        "/health",
        "/meta",
        "/facilities",
        "/service-areas",
        "/gaps",
        "/nearest",
        "/stats",
    } <= set(paths)


# ---------------------------------------------------------------- facilities
def test_facilities_are_valid_geojson(client):
    r = client.get("/facilities")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/geo+json")
    fc = FacilityCollection.model_validate(r.json())
    assert len(fc.features) > 0
    ids = [f.id for f in fc.features]
    assert all(isinstance(i, int) for i in ids) and len(set(ids)) == len(ids)  # unique Feature ids
    for f in fc.features:
        lon, lat = f.geometry.coordinates[0], f.geometry.coordinates[1]
        assert LON_MIN < lon < LON_MAX and LAT_MIN < lat < LAT_MAX
        assert f.properties.in_study


@pytest.mark.parametrize("type_", ["health", "school"])
def test_facilities_filter_by_type(client, type_):
    fc = FacilityCollection.model_validate(client.get("/facilities", params={"type": type_}).json())
    assert fc.features and all(f.properties.type == type_ for f in fc.features)


def test_buffer_adds_facilities(client):
    inside = len(client.get("/facilities").json()["features"])
    with_buffer = client.get("/facilities", params={"include_buffer": True}).json()["features"]
    assert len(with_buffer) > inside
    assert any(not f["properties"]["in_study"] for f in with_buffer)


# ---------------------------------------------------------------- service areas
def test_service_area_is_valid_geojson(client):
    r = client.get("/service-areas", params={"type": "health", "mode": "walk", "minutes": 30})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/geo+json")
    fc = ServiceAreaCollection.model_validate(r.json())
    assert len(fc.features) == 1
    p = fc.features[0].properties
    assert (p.type, p.mode, p.minutes, p.scenario) == ("health", "walk", 30, "base")
    assert 0 < p.buildings_in <= p.buildings_total
    assert p.buildings_pct == pytest.approx(100 * p.buildings_in / p.buildings_total, abs=0.05)


@pytest.mark.parametrize(("mode", "bands"), [("walk", [15, 30, 60]), ("drive", [5, 10, 15])])
def test_longer_band_covers_more(client, mode, bands):
    def buildings_in(minutes):
        params = {"type": "health", "mode": mode, "minutes": minutes}
        r = client.get("/service-areas", params=params)
        return r.json()["features"][0]["properties"]["buildings_in"]

    covered = [buildings_in(m) for m in bands]
    assert covered == sorted(covered)


def test_slower_walking_covers_less(client):
    def pct(scenario):
        r = client.get(
            "/service-areas",
            params={"type": "school", "mode": "walk", "minutes": 15, "scenario": scenario},
        )
        return r.json()["features"][0]["properties"]["buildings_pct"]

    assert pct("walk_slow") < pct("base") < pct("walk_fast")


def test_simplification_shrinks_response(client):
    params = {"type": "health", "mode": "walk", "minutes": 30}
    full = client.get("/service-areas", params={**params, "simplify_m": 0})
    simple = client.get("/service-areas", params={**params, "simplify_m": 25})
    assert len(simple.content) < len(full.content)


@pytest.mark.parametrize(
    ("params", "message"),
    [
        ({"type": "health", "mode": "drive", "minutes": 60}, "choose one of [5, 10, 15]"),
        (
            {"type": "health", "mode": "walk", "minutes": 30, "scenario": "drive_congested"},
            "applies to drive only",
        ),
        ({"type": "health", "mode": "walk", "minutes": 30, "scenario": "nope"}, "Unknown scenario"),
    ],
)
def test_invalid_combinations_are_explained(client, params, message):
    r = client.get("/service-areas", params=params)
    assert r.status_code == 422
    assert message in r.json()["detail"]


@pytest.mark.parametrize(
    "params",
    [
        {"type": "hospital", "mode": "walk", "minutes": 30},  # unknown type
        {"type": "health", "mode": "bike", "minutes": 30},  # unknown mode
        {"type": "health", "mode": "walk"},  # missing minutes
        {"type": "health", "mode": "walk", "minutes": 30, "simplify_m": 500},  # out of range
    ],
)
def test_bad_parameters_are_rejected(client, params):
    assert client.get("/service-areas", params=params).status_code == 422


# ---------------------------------------------------------------- gaps
def test_gaps_are_valid_geojson_sorted_by_buildings(client):
    r = client.get("/gaps", params={"type": "health", "mode": "walk", "minutes": 30})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/geo+json")
    fc = GapCollection.model_validate(r.json())
    counts = [f.properties.n_buildings for f in fc.features]
    assert counts and counts == sorted(counts, reverse=True)


def test_gap_buildings_match_coverage(client):
    """Buildings in the gaps + buildings in the service area = all buildings (within 0.5 %)."""
    params = {"type": "health", "mode": "walk", "minutes": 30}
    in_gaps = sum(
        f["properties"]["n_buildings"]
        for f in client.get("/gaps", params=params).json()["features"]
    )
    p = client.get("/service-areas", params=params).json()["features"][0]["properties"]
    not_covered = p["buildings_total"] - p["buildings_in"]
    assert in_gaps == pytest.approx(not_covered, rel=0.005)


def test_min_buildings_filters_gaps(client):
    params = {"type": "health", "mode": "walk", "minutes": 30}
    all_gaps = client.get("/gaps", params=params).json()["features"]
    big = client.get("/gaps", params={**params, "min_buildings": 500}).json()["features"]
    assert 0 < len(big) < len(all_gaps)
    assert all(f["properties"]["n_buildings"] >= 500 for f in big)


def test_gaps_reject_invalid_band(client):
    r = client.get("/gaps", params={"type": "school", "mode": "walk", "minutes": 5})
    assert r.status_code == 422


# ---------------------------------------------------------------- nearest
def _nearest(client, **params):
    r = client.get("/nearest", params={"type": "health", "mode": "walk", **params})
    return r, {f["properties"]["role"]: f for f in r.json().get("features", [])}


def test_nearest_is_valid_geojson_with_three_roles(client):
    r, by_role = _nearest(client, lat=13.439, lon=-16.680)  # Serekunda
    assert r.status_code == 200
    NearestCollection.model_validate(r.json())
    assert set(by_role) == {"origin", "route", "facility"}
    assert by_role["route"]["properties"]["minutes"] > 0


def test_walking_route_matches_reported_time(client):
    """The drawn route, walked at 4.5 km/h, takes the reported minutes."""
    _, by_role = _nearest(client, lat=13.368, lon=-16.614)  # eastern Kombo North
    route = by_role["route"]["properties"]
    assert route["distance_m"] / (4.5 / 3.6) / 60 == pytest.approx(route["minutes"], abs=0.2)


def test_point_on_a_facility_is_zero_minutes(client):
    facility = client.get("/facilities", params={"type": "health"}).json()["features"][0]
    lon, lat = facility["geometry"]["coordinates"]
    r, by_role = _nearest(client, lat=lat, lon=lon)
    assert r.status_code == 200
    assert by_role["route"]["properties"]["minutes"] == 0
    assert by_role["route"]["geometry"] is None


def test_nearest_respects_mode(client):
    _, walk = _nearest(client, lat=13.368, lon=-16.614, mode="walk")
    _, drive = _nearest(client, lat=13.368, lon=-16.614, mode="drive")
    assert drive["route"]["properties"]["minutes"] < walk["route"]["properties"]["minutes"]


def test_nearest_outside_study_area_is_rejected(client):
    r, _ = _nearest(client, lat=13.50, lon=-16.90)  # Atlantic Ocean
    assert r.status_code == 422
    assert "outside the study area" in r.json()["detail"]


def test_nearest_rejects_scenario_for_other_mode(client):
    r, _ = _nearest(client, lat=13.439, lon=-16.680, scenario="drive_congested")
    assert r.status_code == 422


# ---------------------------------------------------------------- stats and meta
def test_stats_full_table(client):
    rows = [CoverageRow.model_validate(r) for r in client.get("/stats").json()]
    # 2 types x (walk: 3 scenarios + drive: 2 scenarios) x 3 bands
    assert len(rows) == 30
    assert all(0 <= r.pct <= 100 for r in rows)


def test_stats_filters(client):
    rows = client.get("/stats", params={"type": "school", "mode": "drive"}).json()
    assert rows and all(r["type"] == "school" and r["mode"] == "drive" for r in rows)


def test_meta_describes_assumptions(client):
    m = Meta.model_validate(client.get("/meta").json())
    assert m.bands == {"drive": [5, 10, 15], "walk": [15, 30, 60]}
    assert {s.scenario for s in m.scenarios} >= {"base", "walk_slow", "walk_fast"}
    assert m.settings["cell_m"] == 50 and m.settings["access_m"] == 150
    assert m.facilities["health"] > 0 and m.facilities["school"] > 0
    assert "indicative" in m.disclaimer
    assert any(d.name == "osm" for d in m.datasets)


# ---------------------------------------------------------------- travel-time surface
def test_surface_hexes_are_valid_geojson(client):
    r = client.get("/surface/hexes")
    assert r.status_code == 200
    fc = HexCollection.model_validate(r.json())
    ids = [f.id for f in fc.features]
    assert len(ids) > 1000 and len(set(ids)) == len(ids)
    assert "max-age" in r.headers.get("cache-control", "")


def test_surface_rows_match_hexes_and_facilities(client):
    hex_ids = {f["id"] for f in client.get("/surface/hexes").json()["features"]}
    facility_ids = {
        f["id"]
        for f in client.get(
            "/facilities", params={"type": "health", "include_buffer": True}
        ).json()["features"]
    }
    s = Surface.model_validate(
        client.get("/surface", params={"type": "health", "mode": "walk"}).json()
    )
    assert s.bands == [15, 30, 60]
    assert s.hexes
    for hex_id, minutes, facility_id in s.hexes:
        assert hex_id in hex_ids
        assert facility_id in facility_ids
        assert minutes >= 0


def test_surface_rejects_scenario_for_other_mode(client):
    r = client.get("/surface", params={"type": "health", "mode": "drive", "scenario": "walk_fast"})
    assert r.status_code == 422


def test_responses_are_compressed(client):
    r = client.get("/surface/hexes", headers={"Accept-Encoding": "gzip"})
    assert r.headers.get("content-encoding") == "gzip"
