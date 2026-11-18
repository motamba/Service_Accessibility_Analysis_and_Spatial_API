"""The committed OpenAPI file (api/openapi.json) must match the code.

If this fails after an API change, regenerate the file:
    docker compose run --rm test python -m scripts.export_openapi
"""

from scripts.export_openapi import OUT, render


def test_openapi_file_is_up_to_date():
    assert OUT.exists(), "api/openapi.json is missing"
    assert OUT.read_text() == render(), (
        "api/openapi.json is out of date: run "
        "`docker compose run --rm test python -m scripts.export_openapi`"
    )
