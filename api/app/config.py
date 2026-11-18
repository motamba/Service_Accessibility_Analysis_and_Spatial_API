"""Settings, read from environment variables (see docker-compose.yml)."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    database_url: str = "postgresql://gis:gis@localhost:5433/gis"
    # Path prefix when served behind a reverse proxy (e.g. "/api" behind nginx), so the
    # OpenAPI docs link to the right URLs.
    root_path: str = ""
    pool_min_size: int = 1
    pool_max_size: int = 5
    statement_timeout_ms: int = 15000


settings = Settings()
