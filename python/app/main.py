"""TaskFlow Python API.

This is a SKELETON. It starts, connects to Postgres, serves the three health
probes for real, and answers 501 NOT_IMPLEMENTED for every other ``/api/v1``
route. Everything else is a TODO pointing at the roadmap phase that builds it.

Run with ``python -m app.main`` or ``uvicorn app.main:app``.
"""

from __future__ import annotations

import json
import logging
import sys
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response

from app.config import Settings, load_settings
from app.db import create_pool, ping
from app.envelope import new_request_id, new_trace_id, not_implemented
from app.routers import health

_LEVELS = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warn": logging.WARNING,
    "warning": logging.WARNING,
    "error": logging.ERROR,
}


class JsonFormatter(logging.Formatter):
    """Emits the canonical log line from §4.1 of the observability spec.

    TODO(Phase 2): add trace_id, span_id and trace_flags from the active OTel
    span so a log line links back to its trace in Tempo.
    """

    def __init__(self, service_name: str, service_version: str) -> None:
        super().__init__()
        self._service = {"name": service_name, "version": service_version}

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname.lower(),
            "message": record.getMessage(),
            "service": self._service,
        }
        # Anything passed via logger.info(..., extra={"fields": {...}}).
        extra = getattr(record, "fields", None)
        if isinstance(extra, dict):
            payload.update(extra)
        if record.exc_info:
            payload["exception"] = {"stacktrace": self.formatException(record.exc_info)}
        return json.dumps(payload, default=str)


def configure_logging(settings: Settings) -> logging.Logger:
    """Routes application and uvicorn logs through the JSON formatter."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(settings.service_name, settings.service_version))

    level = _LEVELS.get(settings.log_level.lower(), logging.INFO)
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # uvicorn installs its own handlers; replace them so every line on stdout is
    # JSON. Otherwise Loki gets a mix of JSON and uvicorn's plain text.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uv = logging.getLogger(name)
        uv.handlers = [handler]
        uv.propagate = False

    return logging.getLogger("taskflow")


settings = load_settings()
log = configure_logging(settings)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup and graceful shutdown.

    uvicorn traps SIGTERM, stops accepting, waits for in-flight requests to
    finish, and only then runs the shutdown half of this generator — so closing
    the pool here is the drain-then-close ordering the spec asks for.
    """
    pool = await create_pool(settings)
    await ping(pool)  # fail fast: a service that cannot reach its DB should not start
    app.state.pool = pool
    log.info("database pool ready", extra={"fields": {"max_conns": settings.database_pool_size}})

    yield

    # TODO(Phase 6): drain the outbox relay and the Kafka consumer here, before
    # the pool closes — they hold connections too.
    log.info("shutdown signal received")
    await pool.close()
    log.info("shutdown complete")


app = FastAPI(
    title="TaskFlow API (Python)",
    version=settings.service_version,
    lifespan=lifespan,
    # The envelope is hand-rolled, so FastAPI's generated docs would lie about
    # the response shape. docs/openapi.yaml is the normative contract.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.middleware("http")
async def request_context(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    """Stamps every request with a request ID and trace ID, then logs it.

    TODO(Phase 1): honour a well-formed inbound X-Request-Id so a caller can
    correlate across a retry.
    TODO(Phase 2): extract the W3C ``traceparent`` header instead of minting one.
    """
    request_id = new_request_id()
    request.state.request_id = request_id
    request.state.trace_id = new_trace_id()

    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000.0

    response.headers["X-Request-Id"] = request_id

    # TODO(Phase 2): use the matched route template, never the raw path
    # (OBS3.5), plus trace_id, span_id and user.id.
    route = request.scope.get("route")
    log.info(
        "http request completed",
        extra={
            "fields": {
                "http": {
                    "request": {"method": request.method},
                    "route": getattr(route, "path", request.url.path),
                    "response": {"status_code": response.status_code},
                },
                "url": {"path": request.url.path},
                "duration_ms": round(duration_ms, 3),
                "request_id": request_id,
            }
        },
    )
    return response


# TODO(Phase 1): security headers, CORS, body limit, auth middleware.
# TODO(Phase 2): OTel FastAPI instrumentation.
# TODO(Phase 4): valkey-backed rate limiting.
# TODO(Phase 5): concurrency limiter for load shedding.

app.include_router(health.router, prefix="/api/v1/health", tags=["health"])

# TODO(Phase 1):  app.include_router(auth.router, prefix="/api/v1/auth")
# TODO(Phase 1):  app.include_router(tasks.router, prefix="/api/v1/tasks")
# TODO(Phase 10): app.include_router(attachments.router, prefix="/api/v1/attachments")


# Everything else is deliberately 501. Starlette matches routes in registration
# order, so this must stay LAST — include real routers above it.
@app.api_route(
    "/api/v1/{rest:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
    include_in_schema=False,
)
async def catch_all(request: Request, rest: str) -> Response:
    return not_implemented(request)


def main() -> None:
    """Entry point for ``python -m app.main``."""
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",  # noqa: S104 — binding all interfaces is the point in a container
        port=settings.port,
        # uvicorn's own logging is already routed through JsonFormatter above.
        log_config=None,
        access_log=False,  # the middleware emits the canonical line instead
        timeout_graceful_shutdown=int(settings.shutdown_grace_period_s),
        # TODO(Phase 5): timeout_keep_alive and limit_concurrency from
        #   REQUEST_TIMEOUT / MAX_CONCURRENT_REQUESTS.
    )


if __name__ == "__main__":
    main()
