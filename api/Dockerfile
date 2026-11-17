FROM python:3.12-slim-trixie

# uv: fast, locked dependency installs
COPY --from=ghcr.io/astral-sh/uv:0.13.7 /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first (cached layer). DEV=true adds pytest, httpx and ruff for the test service.
ARG DEV=false
COPY pyproject.toml uv.lock ./
RUN if [ "$DEV" = "true" ]; then uv sync --locked --no-install-project; \
    else uv sync --locked --no-install-project --no-dev; fi

COPY . .

RUN useradd --system --uid 10001 app
USER app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
