# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage 1: build dependencies with the full Python toolchain.
# Python minor version (3.11) matches the distroless runtime below so compiled
# wheels (pydantic-core) are ABI compatible.
# ---------------------------------------------------------------------------
FROM python:3.15-slim-bookworm@sha256:96599df822d0e1c6bb700014a05c7f3c8cabc6e0f7ff3c4f9f69cee033b4b5d9 AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
# Install into an isolated prefix that we copy wholesale into the runtime image.
RUN pip install --no-compile --target /install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: distroless runtime - no shell, no package manager, runs as uid 65532.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/python3-debian12:nonroot@sha256:7d1042ce588ab97019fe95c24ffca7bc5a82ccdac572511d5e09bda4435c89c5

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="devops-task-app" \
      org.opencontainers.image.description="Small FastAPI service for the DevOps assessment" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/OWNER/devops-task"

ENV PYTHONPATH=/opt/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080

WORKDIR /opt/app
COPY --from=builder --chown=65532:65532 /install /opt/deps
COPY --chown=65532:65532 app/ ./app/

USER 65532:65532
EXPOSE 8080

# No curl/wget in distroless, so use the interpreter itself for the probe.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python3", "-c", "import os,urllib.request,sys; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8080\")}/health', timeout=2); sys.exit(0)"]

# Exec form => python is PID 1 and receives SIGTERM directly for graceful shutdown.
ENTRYPOINT ["python3", "-m", "app.main"]
