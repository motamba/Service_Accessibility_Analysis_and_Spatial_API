"""Known-answer tests for the routing SQL (etl/sql/40_functions.sql) on the synthetic grid.

Walking 4.5 km/h = 80 s per 100 m edge; driving 36 km/h = 10 s per edge.
See tests/fixtures/grid_network.sql for the layout.
"""

import psycopg
import pytest
from conftest import node_access

WALK_EDGE = 80.0
DRIVE_EDGE = 10.0


# ---------------------------------------------------------------- basic distances
def test_point_on_facility_is_zero_minutes(db):
    access = node_access(db, "health", "walk")
    assert access[1] == (1, pytest.approx(0.0))


def test_walking_time_along_the_grid(db):
    access = node_access(db, "health", "walk")
    assert access[3][1] == pytest.approx(2 * WALK_EDGE)  # 200 m
    assert access[25][1] == pytest.approx(8 * WALK_EDGE)  # opposite corner, 800 m


def test_every_connected_node_is_reached(db):
    access = node_access(db, "health", "walk")
    assert set(access) == set(range(1, 26))


# ---------------------------------------------------------------- nearest of several facilities
def test_nearest_facility_is_chosen(db):
    access = node_access(db, "school", "walk")
    # node 3 is 200 m from node 5 (facilities 3, 4) and 600 m from node 21 (facility 2)
    assert access[3] == (3, pytest.approx(2 * WALK_EDGE))
    # node 16 is 100 m from node 21
    assert access[16] == (2, pytest.approx(WALK_EDGE))


def test_equidistant_node_gets_exact_time(db):
    # node 1 is 400 m from both node 5 and node 21: either facility, but exactly 320 s
    facility, seconds = node_access(db, "school", "walk")[1]
    assert facility in {2, 3}
    assert seconds == pytest.approx(4 * WALK_EDGE)


def test_facilities_sharing_a_node_report_the_lowest_id(db):
    assert node_access(db, "school", "walk")[5] == (3, pytest.approx(0.0))


# ---------------------------------------------------------------- direction and one-way streets
def test_driving_respects_one_way_street(db):
    access = node_access(db, "health", "drive")
    # 2 -> 1 is not allowed: 2 -> 7 -> 6 -> 1 instead of the direct edge
    assert access[2][1] == pytest.approx(3 * DRIVE_EDGE)
    # 3 -> 2 -> 7 -> 6 -> 1  (or 3 -> 8 -> 7 -> 6 -> 1)
    assert access[3][1] == pytest.approx(4 * DRIVE_EDGE)


def test_driving_time_is_measured_towards_the_facility(db):
    # Leaving the facility along 1 -> 2 would take 10 s; getting TO it from node 2 takes 30 s.
    # A search on the forward graph would wrongly give 10 s.
    assert node_access(db, "health", "drive")[2][1] != pytest.approx(DRIVE_EDGE)


def test_walking_ignores_one_way_street(db):
    assert node_access(db, "health", "walk")[2][1] == pytest.approx(WALK_EDGE)


def test_matches_independent_dijkstra_for_every_node(db):
    """Every stored driving time equals pgr_dijkstraCost on the forward graph."""
    access = node_access(db, "health", "drive")
    rows = db.execute(
        "SELECT start_vid, agg_cost FROM pgr_dijkstraCost("
        "  svc.edges_sql('drive', 'base', false), "
        "  ARRAY(SELECT generate_series(2, 25)::bigint), 1::bigint, directed => true)"
    ).fetchall()
    assert len(rows) == 24
    for node, cost in rows:
        assert access[node][1] == pytest.approx(cost), f"node {node}"


# ---------------------------------------------------------------- scenarios and limits
def test_scenario_changes_walking_speed(db):
    # 200 m at 5.0 km/h = 144 s
    assert node_access(db, "health", "walk", "walk_fast")[3][1] == pytest.approx(144.0)


def test_scenario_changes_driving_speed(db):
    # half speed: 3 edges x 20 s
    assert node_access(db, "health", "drive", "drive_slow")[2][1] == pytest.approx(60.0)


def test_nodes_beyond_the_time_limit_are_left_out(db):
    access = node_access(db, "health", "walk", max_seconds=100)
    assert 2 in access  # 80 s
    assert 3 not in access  # 160 s


def test_disconnected_island_is_unreachable(db):
    access = node_access(db, "health", "walk")
    assert 101 not in access and 102 not in access


# ---------------------------------------------------------------- grid cells
def test_cell_halfway_along_an_edge(db):
    node_access(db, "health", "walk")
    node_access(db, "health", "drive")
    db.execute("SELECT svc.compute_cell_access('health', 'walk', 'base')")
    db.execute("SELECT svc.compute_cell_access('health', 'drive', 'base')")
    rows = dict(
        db.execute(
            "SELECT mode, seconds FROM svc.cell_access "
            "WHERE type = 'health' AND scenario = 'base' AND cell_id = 1"
        ).fetchall()
    )
    # walking: 50 m back to the facility node
    assert rows["walk"] == pytest.approx(0.5 * WALK_EDGE)
    # driving: going back towards node 1 would be against the one-way street, so the car goes
    # 50 m on to node 2 (5 s) and then 2 -> 7 -> 6 -> 1 (30 s)
    assert rows["drive"] == pytest.approx(0.5 * DRIVE_EDGE + 3 * DRIVE_EDGE)


# ---------------------------------------------------------------- errors
def test_unknown_scenario_is_rejected(db):
    with pytest.raises(psycopg.errors.RaiseException, match="Unknown scenario"):
        db.execute("SELECT svc.edges_sql('walk', 'no_such_scenario')")


def test_unknown_mode_is_rejected(db):
    with pytest.raises(psycopg.errors.RaiseException, match="Unknown mode"):
        db.execute("SELECT svc.edges_sql('bicycle', 'base')")


def test_type_without_facilities_is_rejected(db):
    with pytest.raises(psycopg.errors.RaiseException, match="No market facilities"):
        db.execute("SELECT svc.compute_node_access('market', 'walk', 'base')")
