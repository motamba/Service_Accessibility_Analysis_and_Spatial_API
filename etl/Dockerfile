FROM debian:trixie-slim

# osm2pgrouting 2.3.8, osmium-tool 1.18, GDAL 3.10, psql 17 (Debian 13 packages)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      osm2pgrouting osmium-tool gdal-bin postgresql-client make curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /etl
COPY . /etl

CMD ["make", "-C", "/etl", "all"]
