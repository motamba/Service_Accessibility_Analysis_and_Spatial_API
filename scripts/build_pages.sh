#!/usr/bin/env bash
# Assemble the static GitHub Pages site: the web map in "static" mode, the exported data
# (web/data, from `docker compose run --rm export`) and the API reference.
#   scripts/build_pages.sh [output-dir]      (default: _site)
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-_site}"

if [ ! -f web/data/meta.json ]; then
    echo "web/data is empty: run 'docker compose run --rm export' first" >&2
    exit 1
fi

rm -rf -- "${out:?}"
mkdir -p "$out"
cp -r web/. "$out"/
rm -f "$out/nginx.conf"
cp api/openapi.json "$out/openapi.json"
sed -i 's/dataSource: "api"/dataSource: "static"/' "$out/config.js"
grep -q 'dataSource: "static"' "$out/config.js"
touch "$out/.nojekyll"

echo "Built $out ($(du -sh "$out" | cut -f1), $(find "$out" -type f | wc -l) files)"
