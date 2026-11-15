# Data pipeline for the Greater Banjul access analysis.
# Runs inside the `etl` container (see docker-compose.yml); connection settings come from
# the standard libpq variables PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD.
#
# Each finished step writes a stamp file in $(STATE), so a re-run skips finished steps and
# a failed run continues where it stopped.  `make reset` forgets all stamps.

.RECIPEPREFIX := >
SHELL         := /bin/bash
.SHELLFLAGS   := -eu -o pipefail -c
.DELETE_ON_ERROR:

include config/study_area.env

DATA  ?= /data
RAW   := $(DATA)/raw
WORK  := $(DATA)/work
STATE := $(DATA)/state
SQL   := sql

PSQL  := psql -X -q -v ON_ERROR_STOP=1
# Scripts: discard result rows (e.g. from meta.log calls); errors and warnings still show.
PSQLF := $(PSQL) -o /dev/null
export PGOPTIONS := -c client_min_messages=warning
PG    := PG:dbname=$(PGDATABASE)
OGR   := ogr2ogr -f PostgreSQL $(PG) -overwrite -lco GEOMETRY_NAME=geom -lco FID=id -t_srs EPSG:32628

GEOFABRIK_URL := https://download.geofabrik.de/africa/senegal-and-gambia-latest.osm.pbf
CODAB_URL     := https://data.humdata.org/dataset/9f2ce756-2e50-4042-a952-32160977d223/resource/7dec73e0-1c4f-403c-953e-cdad41c01b0e/download/gmb_admin_boundaries.geojson.zip

COUNTRY_PBF := $(RAW)/osm/senegal-and-gambia-latest.osm.pbf
ADMIN2      := $(RAW)/boundaries/gmb_admin2.geojson
CLIP_PBF    := $(WORK)/greater_banjul.osm.pbf

.PHONY: all pipeline sync-state reset status
# Two stages (recursive make) so the stamp files are re-read after sync-state.
all:
> @$(MAKE) --no-print-directory sync-state
> @$(MAKE) --no-print-directory pipeline
> @echo "Pipeline finished."
> @$(MAKE) --no-print-directory status

pipeline: $(STATE)/land $(STATE)/network

# Stamps live in ./data but the database lives in a Docker volume. If the database was
# recreated (e.g. `docker compose down -v`), the stamps are stale: forget them.
sync-state:
> @if [ -d $(STATE) ] && [ -z "$$($(PSQL) -tAc "SELECT to_regclass('meta.import_log')")" ]; then \
>     echo "Database is empty but stamps exist: rebuilding from scratch."; rm -rf $(STATE); fi

reset:
> rm -rf $(STATE)

status:
> @$(PSQL) -c "SELECT step, item, value FROM meta.import_log ORDER BY id"

# ---------------------------------------------------------------- downloads
$(COUNTRY_PBF):
> mkdir -p $(@D)
> curl -fSL --retry 3 -o $@.part $(GEOFABRIK_URL)
> curl -fsSL -o $@.md5 $(GEOFABRIK_URL).md5
> echo "$$(cut -d' ' -f1 $@.md5)  $@.part" | md5sum -c -
> mv $@.part $@

$(ADMIN2):
> mkdir -p $(@D)
> curl -fSL --retry 3 -o $(@D)/cod_ab.geojson.zip "$(CODAB_URL)"
> unzip -o -q $(@D)/cod_ab.geojson.zip -d $(@D)
> touch $@

# ---------------------------------------------------------------- database
$(STATE)/schemas: $(SQL)/00_schemas.sql
> mkdir -p $(STATE)
> $(PSQLF) -f $<
> touch $@

$(STATE)/boundaries: $(ADMIN2) $(SQL)/10_study_area.sql config/study_area.env $(STATE)/schemas
> $(OGR) -nln ref.admin2 -nlt PROMOTE_TO_MULTI $(ADMIN2)
> $(PSQLF) -v study_adm2="$(STUDY_ADM2)" -v buffer_m=$(BUFFER_M) -f $(SQL)/10_study_area.sql
> $(PSQL) -c "INSERT INTO meta.dataset (name, source_url, licence, data_date) \
>             VALUES ('boundaries', '$(CODAB_URL)', 'CC BY-IGO (OCHA COD-AB)', '2022-09-01 (valid_on)') \
>             ON CONFLICT (name) DO UPDATE SET retrieved_at = now()"
> mkdir -p $(WORK)
> rm -f $(WORK)/study_buffer.geojson
> ogr2ogr -f GeoJSON $(WORK)/study_buffer.geojson $(PG) \
>     -sql "SELECT ST_Transform(geom_buffer, 4326) AS geom FROM ref.study_area"
> touch $@

# ---------------------------------------------------------------- OSM clip
# "smart" keeps complete ways that cross the buffer edge, so roads are not cut mid-segment.
$(CLIP_PBF): $(COUNTRY_PBF) $(STATE)/boundaries
> osmium extract --overwrite --strategy smart -p $(WORK)/study_buffer.geojson $(COUNTRY_PBF) -o $@
> OSM_DATE=$$(osmium fileinfo -g header.option.osmosis_replication_timestamp $(COUNTRY_PBF)); \
> $(PSQL) -c "INSERT INTO meta.dataset (name, source_url, licence, data_date) \
>             VALUES ('osm', '$(GEOFABRIK_URL)', 'ODbL 1.0 (© OpenStreetMap contributors)', '$$OSM_DATE') \
>             ON CONFLICT (name) DO UPDATE SET data_date = EXCLUDED.data_date, retrieved_at = now()"

# ---------------------------------------------------------------- water and land
$(STATE)/land: $(CLIP_PBF) $(SQL)/15_land.sql
> osmium tags-filter --overwrite $(CLIP_PBF) nwr/natural=water nwr/water nwr/waterway=riverbank \
>     -o $(WORK)/water.osm.pbf
> $(OGR) -nln ref.water_raw -nlt PROMOTE_TO_MULTI $(WORK)/water.osm.pbf multipolygons
> $(PSQLF) -f $(SQL)/15_land.sql
> touch $@

# ---------------------------------------------------------------- road network
# osm2pgrouting reads OSM XML only; filtering to highway ways first keeps the file small.
$(WORK)/roads.osm: $(CLIP_PBF)
> osmium tags-filter --overwrite $(CLIP_PBF) w/highway -o $(WORK)/roads.osm.pbf
> osmium cat --overwrite $(WORK)/roads.osm.pbf -o $@

# Raw import: net.ways, net.ways_vertices_pgr, net.configuration
$(STATE)/roads: $(WORK)/roads.osm config/mapconfig.xml $(STATE)/schemas
> osm2pgrouting --f $(WORK)/roads.osm --conf config/mapconfig.xml --schema net --clean \
>     --dbname $(PGDATABASE) --host $(PGHOST) --port $(PGPORT) --username $(PGUSER) --password $(PGPASSWORD) \
>     | grep -vE '^\s*$$|^ *\[' || true
> $(PSQL) -tAc "SELECT count(*) || ' ways imported' FROM net.ways"
> touch $@

# Clean edge table, speeds, scenarios, connected components
$(STATE)/network: $(STATE)/roads $(SQL)/20_network.sql config/speeds.csv config/scenarios.csv
> $(PSQLF) -f $(SQL)/20_network.sql
> touch $@
