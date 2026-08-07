"""Runtime configuration, read from the environment.

Every key here appears in the repository-root ``.env.example``. Only the subset
the skeleton actually uses is parsed; the rest arrive in later phases.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

_DURATION_RE = re.compile(r"^(\d+(?:\.\d+)?)(ms|s|m|h)$")
_UNIT_SECONDS = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}


def _str(key: str, fallback: str) -> str:
    value = os.environ.get(key, "")
    return value if value else fallback


def _int(key: str, fallback: int) -> int:
    value = os.environ.get(key, "")
    if not value:
        return fallback
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"{key} must be an integer, got {value!r}") from exc


def _duration_seconds(key: str, fallback: float) -> float:
    """Parses a Go-style duration ("30s", "5m", "1500ms") into seconds.

    ``.env.example`` uses that format for the shutdown keys, so all five
    services have to understand it.
    """
    value = os.environ.get(key, "").strip()
    if not value:
        return fallback
    match = _DURATION_RE.match(value)
    if match is None:
        return fallback
    return float(match.group(1)) * _UNIT_SECONDS[match.group(2)]


@dataclass(frozen=True)
class Settings:
    """The subset of ``.env.example`` the skeleton needs today."""

    port: int
    env: str
    service_name: str
    service_version: str
    log_level: str
    database_url: str
    database_pool_size: int
    database_min_idle: int
    database_acquire_timeout_s: float
    shutdown_grace_period_s: float

    # TODO(Phase 1): jwt_secret, jwt_issuer, jwt_audience, jwt_access_expiry,
    #   jwt_refresh_expiry, bcrypt_cost, cors_origins, max_body_bytes.
    # TODO(Phase 4): valkey_url, cache_enabled, rate_limit_* keys.
    # TODO(Phase 6): kafka_brokers, outbox_* keys.
    # TODO(Phase 10): s3_endpoint, s3_bucket, s3_access_key, s3_secret_key.


def load_settings() -> Settings:
    """Reads the environment and raises on anything missing or malformed.

    Failing at startup beats failing on the first request that needs the value.
    """
    database_url = os.environ.get("DATABASE_URL", "")
    if not database_url:
        raise ValueError("DATABASE_URL is required")

    return Settings(
        port=_int("PORT", 8080),
        env=_str("ENV", "development"),
        service_name=_str("OTEL_SERVICE_NAME", "taskflow-python"),
        service_version=_str("OTEL_SERVICE_VERSION", "1.0.0"),
        log_level=_str("LOG_LEVEL", "info"),
        database_url=database_url,
        database_pool_size=_int("DATABASE_POOL_SIZE", 10),
        database_min_idle=_int("DATABASE_MIN_IDLE", 2),
        database_acquire_timeout_s=_int("DATABASE_ACQUIRE_TIMEOUT_MS", 2000) / 1000.0,
        shutdown_grace_period_s=_duration_seconds("SHUTDOWN_GRACE_PERIOD", 30.0),
    )
