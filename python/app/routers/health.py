"""The three health probes (OBS5).

Why three endpoints: a single ``/health`` that checks the database is the most
common self-inflicted outage in production. The database blips, every replica
fails its *liveness* probe at once, the orchestrator kills them all, and a
recoverable dependency blip becomes a total outage. Liveness answers only "is
this process wedged". Readiness answers "should I get traffic now".
"""

from __future__ import annotations

import asyncio
import time

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app.db import ping
from app.envelope import failure, success

router = APIRouter()

#: OBS5.4 — a probe that hits the database on every call is itself a risk.
READY_CACHE_TTL_S = 1.0
#: OBS5.4 — hard ceiling on the dependency check.
READY_TIMEOUT_S = 2.0

# Module-level cache. One process, one event loop, so a plain tuple is enough;
# the GIL makes the read-modify-write safe without a lock. Under Gunicorn with
# multiple workers each worker keeps its own cache, which is correct — readiness
# is a per-process question.
_ready_cache: tuple[float, bool] | None = None


async def _check_cached(request: Request) -> bool:
    """Runs ``SELECT 1``, memoising the result for ``READY_CACHE_TTL_S``."""
    global _ready_cache

    now = time.monotonic()
    if _ready_cache is not None and now - _ready_cache[0] < READY_CACHE_TTL_S:
        return _ready_cache[1]

    pool = request.app.state.pool
    try:
        await asyncio.wait_for(ping(pool), timeout=READY_TIMEOUT_S)
        healthy = True
    except Exception:
        # Deliberately broad: a readiness probe must report "not ready" for any
        # failure, not raise 500 and let the orchestrator guess.
        healthy = False

    _ready_cache = (now, healthy)
    return healthy


@router.get("/live")
async def live(request: Request) -> JSONResponse:
    """OBS5.1 — liveness. No dependency checks, ever."""
    return success(request, 200, {"status": "alive"})


async def _ready(request: Request) -> JSONResponse:
    """OBS5.2 — readiness.

    TODO(Phase 4): add the Valkey PING here.
    TODO(Phase 6): add the Kafka broker metadata check here.
    """
    if not await _check_cached(request):
        # The envelope invariant is absolute: a >=400 status carries
        # success:false and error.code. The detail travels in error.details so
        # an operator still sees which dependency failed.
        return failure(
            request,
            503,
            "SERVICE_UNAVAILABLE",
            "One or more dependencies are unavailable",
            {"status": "not_ready", "checks": {"database": "down"}},
        )
    return success(request, 200, {"status": "ready", "checks": {"database": "up"}})


@router.get("/ready")
async def ready(request: Request) -> JSONResponse:
    return await _ready(request)


@router.get("")
@router.get("/")
async def health_alias(request: Request) -> JSONResponse:
    """OBS5.5 — ``/api/v1/health`` stays as an alias of ``/health/ready``."""
    return await _ready(request)


@router.get("/startup")
async def startup(request: Request) -> JSONResponse:
    """OBS5.3 — startup.

    The pool is created and pinged in the lifespan handler before the server
    accepts traffic, so reaching this handler at all means startup succeeded.

    TODO(Phase 0/12): also assert the expected schema_migrations version, so a
    replica pointed at an un-migrated database never reports started.
    """
    return success(request, 200, {"status": "started"})
