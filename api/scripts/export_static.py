"""Export the API's responses as static files for the GitHub Pages demo (web/data).

    docker compose run --rm export

The API is called in-process (FastAPI TestClient), so every file is exactly what the API would
return. File names follow web/app.js (dataUrl). Layers derived from OpenStreetMap: ODbL.
"""

import json
import shutil
import sys
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import app

TYPES = ("health", "school")
# Generated sub-folders and files; only these are removed before a new export.
GENERATED = ("service-areas", "gaps", "surface")


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name in GENERATED:
        shutil.rmtree(out / name, ignore_errors=True)
    for old in out.glob("*.json"):
        old.unlink()
    for old in out.glob("*.geojson"):
        old.unlink()

    sizes: dict[str, int] = {}

    with TestClient(app) as client:

        def get(path: str, **params):
            r = client.get(path, params=params)
            r.raise_for_status()
            return r.json()

        def write(rel: str, data) -> None:
            path = out / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            text = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
            path.write_text(text)
            group = rel.split("/")[0] if "/" in rel else rel
            sizes[group] = sizes.get(group, 0) + len(text.encode())

        meta = get("/meta")
        write("meta.json", meta)
        write("stats.json", get("/stats"))
        write("surface/hexes.geojson", get("/surface/hexes"))
        for t in TYPES:
            # with the buffer: the static demo needs every facility a hexagon can point to
            write(f"facilities_{t}.geojson", get("/facilities", type=t, include_buffer=True))

        n = 0
        for mode, bands in meta["bands"].items():
            scenarios = [
                s["scenario"] for s in meta["scenarios"] if s["applies_to"] in (mode, "both")
            ]
            for scenario in scenarios:
                for t in TYPES:
                    key = f"{t}_{mode}_{scenario}"
                    write(
                        f"surface/{key}.json", get("/surface", type=t, mode=mode, scenario=scenario)
                    )
                    for minutes in bands:
                        p = {"type": t, "mode": mode, "minutes": minutes, "scenario": scenario}
                        write(f"service-areas/{key}_{minutes}.geojson", get("/service-areas", **p))
                        write(f"gaps/{key}_{minutes}.geojson", get("/gaps", **p))
                        n += 1

    total = sum(sizes.values())
    print(f"Exported {n} type/mode/scenario/band combinations to {out}", file=sys.stderr)
    for group, size in sorted(sizes.items()):
        print(f"  {group:<28} {size / 1e6:6.2f} MB", file=sys.stderr)
    print(f"  {'total':<28} {total / 1e6:6.2f} MB", file=sys.stderr)


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "/out"))
