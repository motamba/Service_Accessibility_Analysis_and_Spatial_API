# Access to Services in Greater Banjul — Spatial Analysis and API

How long does it take to walk or drive to the nearest health facility or school in Greater Banjul, The Gambia, and which areas are left out?

This project builds the answer with **PostgreSQL + PostGIS + pgRouting**, serves it through a documented **REST API (FastAPI, GeoJSON)** and shows it on a **web map (MapLibre)**. Everything runs with one `docker compose up`.

> **Status:** in development (personal portfolio project, November–December 2026).
> Results are **indicative estimates based on OpenStreetMap data** and must not be used for real planning or emergency decisions.

---

## Quick start

Requirements: Docker with Docker Compose.

```bash
git clone <repo-url> && cd service-accessibility-api-greater-banjul
docker compose up --build
```

The first run downloads the data (about 100 MB) and builds the database. Later runs skip finished steps.

Connect QGIS or `psql` to the database on `localhost:5433` (database `gis`, user `gis`, password `gis`; override in `.env`, see `.env.example`).

Useful commands:

```bash
docker compose run --rm etl make status   # import counts so far
docker compose run --rm etl make reset    # forget finished steps, rebuild on next run
docker compose down -v                    # remove containers and the database volume
```

---

## Study area

**Greater Banjul** is defined as the union of these admin-2 units from the OCHA COD-AB boundaries (valid on 1 Sep 2022):

| LGA | Units (p-code) |
|---|---|
| Banjul City Council | Banjul Central (GM0101), Banjul North (GM0102), Banjul South (GM0103) |
| Kanifing Municipal Council | Bakau (GM0501), Jeshwang (GM0502), Mangrove (GM0503), Sere Kunda Central (GM0504), Sere Kunda East (GM0505), Sere Kunda West (GM0506) |
| Brikama LGA (part) | Kombo North/St Marie (GM0308) |

Total area 283.4 km², of which 271.5 km² is land after removing OSM water areas (rivers and creeks such as the Gambia River estuary and Mandina Ba Bolong). Mangrove wetlands (Tanbi) are kept as land; because they are largely uninhabited, gap results are reported mainly as **numbers of buildings**, not only as area. Roads and facilities are loaded for the study area **plus a 5 km buffer**, so that facilities just outside the boundary still count for people inside it. Results are reported for the study area only. The list of units is in [`etl/config/study_area.env`](etl/config/study_area.env).

---

## Data sources and licences

| Data | Source | Licence | Used for |
|---|---|---|---|
| Roads, facilities, water | [OpenStreetMap](https://www.openstreetmap.org/copyright) via [Geofabrik](https://download.geofabrik.de/africa/senegal-and-gambia.html) "Senegal and Gambia" extract | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/) — © OpenStreetMap contributors | Routing graph, facilities, water mask |
| Administrative boundaries | [OCHA COD-AB, The Gambia](https://data.humdata.org/dataset/cod-ab-gmb) (HDX) | CC BY-IGO | Study area |
| Buildings | Google Open Buildings v3 *(to be added, day 4)* | CC BY 4.0 / ODbL | Counting buildings in gap areas |

The exact OSM data date is stored in the database table `meta.dataset` and will be listed here with the results.

**Share-alike:** the published GeoJSON layers are derived from OpenStreetMap and are therefore made available under the ODbL.

---

## Project structure

```
db/init/          database extensions (runs when the volume is first created)
etl/              data pipeline: Dockerfile, Makefile, config/, sql/
data/             downloads and intermediate files (not in git)
```

More parts (API, web map, tests) are added as development continues.

---

## Licence

Code: MIT (see [LICENSE](LICENSE)). Data products: ODbL, as above.
