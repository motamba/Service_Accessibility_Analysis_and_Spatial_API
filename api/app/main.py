"""Greater Banjul access API: travel-time access to health facilities and schools, as GeoJSON."""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.db import pool
from app.meta import meta
from app.routers import facilities, gaps, health, info, nearest, service_areas, stats
from app.text import ATTRIBUTION, DISCLAIMER, TITLE

DESCRIPTION = """
Travel-time access to **health facilities** and **schools** in Greater Banjul, The Gambia,
computed with PostgreSQL, PostGIS and pgRouting from OpenStreetMap and other open data.

All geometries are GeoJSON in WGS 84 (EPSG:4326).

"""


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True, timeout=30)
    meta.load()
    yield
    pool.close()


app = FastAPI(
    title=TITLE,
    version="0.1.0",
    description=f"{DESCRIPTION}\n**{DISCLAIMER}**\n\nData: {ATTRIBUTION}",
    root_path=settings.root_path,
    lifespan=lifespan,
)

# Read-only public data: any web page may call it.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET"])

for module in (health, info, facilities, service_areas, gaps, nearest, stats):
    app.include_router(module.router)
