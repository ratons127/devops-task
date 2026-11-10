"""Application configuration, read exclusively from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool = False) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    port: int
    log_level: str
    environment: str
    app_version: str
    enable_chaos: bool
    shutdown_timeout: int

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            port=int(os.getenv("PORT", "8080")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            environment=os.getenv("APP_ENV", "development"),
            app_version=os.getenv("APP_VERSION", "0.0.0-dev"),
            # Exposes GET /error for demoing alerts/dashboards. Never enable in production.
            enable_chaos=_env_bool("ENABLE_CHAOS_ENDPOINT", False),
            shutdown_timeout=int(os.getenv("SHUTDOWN_TIMEOUT_SECONDS", "10")),
        )
