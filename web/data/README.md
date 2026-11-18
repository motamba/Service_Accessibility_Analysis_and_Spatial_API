# Pre-computed layers (GitHub Pages demo)

These files are the API's responses, exported with `docker compose run --rm export`
(`api/scripts/export_static.py`). They let the web map run without a backend.

| Files | Content |
|---|---|
| `meta.json`, `stats.json` | assumptions, data sources, building coverage table |
| `facilities_{type}.geojson` | facilities (study area and 5 km buffer) |
| `service-areas/{type}_{mode}_{scenario}_{minutes}.geojson` | land within the time band |
| `gaps/{type}_{mode}_{scenario}_{minutes}.geojson` | areas beyond the time band, with building counts |
| `surface/hexes.geojson`, `surface/{type}_{mode}_{scenario}.json` | travel-time surface (200 m hexagons) |

All geometries are GeoJSON in WGS 84. **Results are indicative estimates** and must not be used
for real planning or emergency decisions.

## Licence

These layers are derived from OpenStreetMap and are made available under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).

Attribution: © OpenStreetMap contributors; Maina, J. et al. (2019), *Scientific Data* 6, 134
(CC BY 4.0); Google Open Buildings v3 (CC BY 4.0 / ODbL); OCHA COD-AB boundaries for The Gambia
(CC BY-IGO).
