import json
import logging

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.logging_setup import JsonFormatter


@pytest.fixture()
def client():
    with TestClient(main.app) as c:
        yield c


def test_root_returns_banner(client):
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["message"] == "Hello from DevOps Task!"
    assert body["status"] == "running"
    assert body["version"] == main.settings.app_version


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_metrics_exposes_required_series(client):
    client.get("/")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    text = resp.text
    assert 'http_requests_total{method="GET",path="/",status="200"}' in text
    assert "http_request_duration_seconds_bucket" in text
    assert "http_request_errors_total" in text


def test_unknown_path_uses_bounded_label(client):
    client.get("/does-not-exist-12345")
    text = client.get("/metrics").text
    assert "does-not-exist-12345" not in text
    assert 'path="unmatched"' in text


def test_error_endpoint_hidden_by_default(client):
    assert client.get("/error").status_code == 404


def test_error_endpoint_counts_errors_when_enabled(client, monkeypatch):
    monkeypatch.setattr(main, "settings", Settings(8080, "INFO", "test", "1.0.0", True, 5))
    assert client.get("/error").status_code == 500
    text = client.get("/metrics").text
    assert 'http_request_errors_total{method="GET",path="/error"}' in text


def test_settings_read_from_env(monkeypatch):
    monkeypatch.setenv("PORT", "9090")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    s = Settings.from_env()
    assert (s.port, s.log_level, s.environment) == (9090, "DEBUG", "staging")


def test_json_formatter_emits_valid_json():
    fmt = JsonFormatter("svc", "test", "1.2.3")
    record = logging.LogRecord("app", logging.INFO, __file__, 1, "hello", None, None)
    record.path = "/"
    record.status = 200
    out = json.loads(fmt.format(record))
    assert out["level"] == "info"
    assert out["message"] == "hello"
    assert out["path"] == "/"
    assert out["env"] == "test"
