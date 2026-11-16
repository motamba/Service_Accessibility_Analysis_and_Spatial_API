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

## Assumptions

Travel times use simple, fixed speeds. They describe free-flowing conditions, not real traffic.

| Item | Value |
|---|---|
| Walking speed | 4.5 km/h on every road and path |
| Driving speeds by OSM `highway` class (km/h) | trunk 60 · primary 50 · secondary 40 · tertiary 30 · unclassified / residential / living_street / road 20 · service 15 · track 10 · links 25–40 · footway, path, pedestrian, steps, cycleway, bridleway: no driving |
| One-way streets | Respected for driving, ignored for walking |
| Ferries | Excluded |
| Disconnected road fragments | Only the main connected network is used: for driving, the largest *strongly* connected part (every node can both reach and be reached) |
| Measuring CRS | WGS 84 / UTM zone 28N (EPSG:32628) |

Speeds are in [`etl/config/speeds.csv`](etl/config/speeds.csv). The sensitivity scenarios in [`etl/config/scenarios.csv`](etl/config/scenarios.csv) re-run the analysis with walking at 4.0 and 5.0 km/h, and with all driving speeds × 0.6 as a simple congestion proxy.

---

## Facilities

| Type | What counts | Source |
|---|---|---|
| Health | OSM `amenity` = hospital, clinic, doctors, or `healthcare` = hospital, clinic, centre, doctor. Pharmacies, dentists and other specialists are not counted. | OpenStreetMap, plus public facilities from Maina et al. (2019) |
| School | OSM `amenity=school`. Kindergartens, colleges and universities are not counted. | OpenStreetMap |

How the facility layer is built:

- A facility mapped as an area becomes a point with `ST_PointOnSurface`. A point of the same type within 50 m of an area is treated as the same facility.
- **OpenStreetMap alone misses many public health centres** in Greater Banjul (e.g. Bakau, Banjul Polyclinic, Brufut, Leman Street). They are added from the Maina et al. (2019) list of public health facilities.
- Maina coordinates are geocoded and can be 0.5–2 km off, so the two sources are matched **by name** (trigram similarity of names without generic words such as "health centre"), within 2.5 km, keeping only mutual best matches. Matched facilities keep the OSM location. The matches are stored in `svc.facility_matches`.
- Each facility is snapped to the nearest junction of the main road network, separately for walking and driving. Facilities in the 5 km buffer that are more than 1 km from any road cannot serve the study area and are dropped (e.g. Essau, across the river).

---

## Method: travel time to the nearest facility

For every junction of the road network, the pipeline computes the travel time to the nearest facility of each type, for each mode and speed scenario (`svc.node_access`).

- **One search per facility type, mode and scenario.** A virtual *super-source* node is joined to every facility by a zero-cost edge, and a single `pgr_drivingDistance` (Dijkstra) run from it gives each junction its time to the nearest facility (up to 60 min). Following the search tree back to its root shows which facility that is.
- **Direction matters for driving.** Times are measured from the junction *to* the facility, so for driving the search runs on the reversed graph (one-way streets are traversed backwards).
- **Independently checked.** At the end of every run, the times of a fixed sample of junctions are recomputed with `pgr_dijkstraCost` on the forward graph and must match to 0.01 s.
- **Why not pgRouting's built-in multi-root mode?** With `equicost => true`, pgRouting 3.8.0 returned non-optimal times for some junctions (for example 1,175 s instead of 1,162 s). The cross-check caught this, and the super-source method replaced it.

Median time from a road junction in the study area to the nearest facility (all scenarios):

| | Walk 4.0 / 4.5 / 5.0 km/h | Drive free flow / congested (× 0.6) |
|---|---|---|
| Health facility | 22.4 / **20.6** / 18.8 min | **4.1** / 6.9 min |
| School | 16.8 / **15.0** / 13.5 min | **3.0** / 5.0 min |

---

## Data quality (current run)

| Measure | Value |
|---|---|
| Road segments / junctions | 49,747 / 34,071 |
| Road length (of which drivable) | 4,539 km (4,423 km) |
| One-way segments | 1,095 |
| Road length in the main connected network | walking 99.3 % (29 fragments), driving 99.3 % (9 fragments) |
| Health facilities in the study area | 37: 26 from OSM + 11 added from Maina et al. (5 more Maina facilities matched to OSM) — 21 hospitals, 6 health centres, 10 clinics |
| Schools in the study area | 81 (all OSM); 15.5 % without a name |
| Facilities in the 5 km buffer (also used for routing) | 47 health, 103 schools; 1 dropped as unreachable |
| Distance from facility to the road network | median 47 m, max 284 m; none over 500 m |
| Buildings in the study area | 160,491 (Google Open Buildings v3, confidence ≥ 0.782) |

Sanity check: Albert Market (Banjul) to Serekunda market takes 14 min by car (13.4 km, free flow) and 174 min on foot (13.2 km); the straight-line distance is 10.9 km.

---

## Data sources and licences

| Data | Source | Licence | Used for |
|---|---|---|---|
| Roads, facilities, water | [OpenStreetMap](https://www.openstreetmap.org/copyright) via [Geofabrik](https://download.geofabrik.de/africa/senegal-and-gambia.html) "Senegal and Gambia" extract | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/) — © OpenStreetMap contributors | Routing graph, facilities, water mask |
| Administrative boundaries | [OCHA COD-AB, The Gambia](https://data.humdata.org/dataset/cod-ab-gmb) (HDX) | CC BY-IGO | Study area |
| Public health facilities | Maina, J. et al. (2019). *A spatial database of health facilities managed by the public health sector in sub-Saharan Africa.* Scientific Data 6, 134. Via [HDX](https://data.humdata.org/dataset/health-facilities-in-sub-saharan-africa) | CC BY 4.0 | Health facilities missing from OSM |
| Buildings | [Google Open Buildings v3](https://sites.research.google/open-buildings/), points, tile `0ed` | CC BY 4.0 / ODbL 1.0 | Counting buildings in gap areas and travel-time bands |

Buildings are kept when their confidence is at least **0.782**, Google's published threshold for 85 % precision in this tile. The exact OSM data date is stored in the database table `meta.dataset` and will be listed here with the results.

**Share-alike:** the published GeoJSON layers are derived from OpenStreetMap and are therefore made available under the ODbL, with attribution to all sources above.

### Known data limitations

- **Schools are probably under-counted.** OSM has 81 schools in the study area and no open alternative list was found; areas may show as "gaps" because a school is not mapped.
- **OSM tags are sometimes wrong** (e.g. a pharmacy tagged as a hospital, clinics tagged as hospitals), so facility subtypes are indicative.
- **The public facility list is from 2019** and covers public, NGO and community facilities only; private clinics come from OSM alone.
- **Building points are detected from satellite imagery** and include some false detections and missed buildings.

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
