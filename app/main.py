"""DevOps task web service.

Endpoints:
  GET /         -> service banner with version
  GET /health   -> liveness/readiness check
  GET /metrics  -> Prometheus metrics
  GET /error    -> returns 500 (only when ENABLE_CHAOS_ENDPOINT=true; for alert demos)
"""

from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.config import Settings
from app.logging_setup import configure_logging
from app.metrics import APP_INFO, IN_PROGRESS, REQUEST_COUNT, REQUEST_ERRORS, REQUEST_LATENCY

settings = Settings.from_env()
configure_logging(settings.log_level, settings.environment, settings.app_version)
logger = logging.getLogger("app")


@asynccontextmanager
async def lifespan(_: FastAPI):
    APP_INFO.labels(version=settings.app_version, env=settings.environment).set(1)
    logger.info("application started", extra={"event": "startup"})
    yield
    # Runs after uvicorn receives SIGTERM and has drained in-flight requests.
    logger.info("application shutting down gracefully", extra={"event": "shutdown"})


app = FastAPI(title="devops-task-app", version=settings.app_version, lifespan=lifespan)


def _route_template(request: Request) -> str:
    """Return the matched route path (e.g. '/items/{id}') or a fixed bucket for 404s."""
    route = request.scope.get("route")
    return getattr(route, "path", "unmatched")


@app.middleware("http")
async def observe_requests(request: Request, call_next):
    start = time.perf_counter()
    IN_PROGRESS.inc()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        IN_PROGRESS.dec()
        duration = time.perf_counter() - start
        path = _route_template(request)
        method = request.method
        REQUEST_COUNT.labels(method=method, path=path, status=str(status)).inc()
        REQUEST_LATENCY.labels(method=method, path=path).observe(duration)
        if status >= 500:
            REQUEST_ERRORS.labels(method=method, path=path).inc()

        # Don't flood logs with scrape/probe traffic.
        if path not in ("/metrics", "/health"):
            level = logging.ERROR if status >= 500 else logging.INFO
            logger.log(
                level,
                "request completed",
                extra={
                    "event": "http_request",
                    "method": method,
                    "path": path,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client_ip": request.client.host if request.client else None,
                },
            )


@app.get("/")
async def root() -> dict:
    return {"message": "Hello from DevOps Task!", "status": "running", "version": settings.app_version}


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/error")
async def error() -> dict:
    if not settings.enable_chaos:
        raise HTTPException(status_code=404, detail="Not Found")
    raise HTTPException(status_code=500, detail="Simulated failure")


def run() -> None:
    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 - must listen on all interfaces inside a container
        port=settings.port,
        log_config=None,  # keep our JSON logging configuration
        timeout_graceful_shutdown=settings.shutdown_timeout,
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()
