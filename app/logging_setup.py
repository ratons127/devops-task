"""Structured JSON logging to stdout (one JSON object per line)."""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

# Fields that may be attached via `logger.info("...", extra={...})`.
_EXTRA_FIELDS = ("method", "path", "status", "duration_ms", "client_ip", "event")


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str, environment: str, version: str) -> None:
        super().__init__()
        self._static = {"service": service, "env": environment, "version": version}

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname.lower(),
            "logger": record.name,
            "message": record.getMessage(),
            **self._static,
        }
        for field in _EXTRA_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


def configure_logging(level: str, environment: str, version: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter("devops-task-app", environment, version))

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # Route uvicorn's own loggers through the JSON handler; drop its access log
    # because our middleware emits a richer structured access log.
    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers = []
        lg.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
