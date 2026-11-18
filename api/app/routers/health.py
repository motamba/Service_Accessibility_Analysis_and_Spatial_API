from fastapi import APIRouter
from psycopg import OperationalError

from app.db import fetch_value
from app.schemas import Health

router = APIRouter(tags=["status"])


@router.get("/health", response_model=Health, summary="Service and database status")
def health() -> Health:
    try:
        osm_date = fetch_value("SELECT data_date FROM meta.dataset WHERE name = 'osm'")
        return Health(status="ok", database=True, osm_data_date=osm_date)
    except OperationalError:
        return Health(status="degraded", database=False, osm_data_date=None)
