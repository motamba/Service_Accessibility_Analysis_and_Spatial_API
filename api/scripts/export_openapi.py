"""Write the API's OpenAPI description to openapi.json (no database needed).

    docker compose run --rm test python -m scripts.export_openapi

tests/test_openapi.py fails when the committed file no longer matches the code.
"""

import json
import sys
from pathlib import Path

from app.main import app

OUT = Path(__file__).resolve().parents[1] / "openapi.json"


def render() -> str:
    return json.dumps(app.openapi(), indent=2, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    OUT.write_text(render())
    print(f"wrote {OUT}", file=sys.stderr)
