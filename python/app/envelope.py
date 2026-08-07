"""The HTTP response envelope and the request-scoped identifiers every
TaskFlow response carries.

The shape here is normative — the language-neutral conformance suite asserts it
across all five implementations. Do not change a field name without changing
the other four services too.
"""

from __future__ import annotations

import secrets
from datetime import UTC, datetime
from typing import Any

from fastapi import Request
from fastapi.responses import JSONResponse

_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


def new_request_id() -> str:
    """``req_`` followed by 12 alphanumeric characters."""
    return "req_" + "".join(secrets.choice(_ALPHABET) for _ in range(12))


def new_trace_id() -> str:
    """32 lowercase hex characters.

    TODO(Phase 2): delete this. Once the OpenTelemetry SDK is wired up the trace
    ID must come from the active span context, or ``meta.traceId`` will not
    resolve in Tempo. Random is a placeholder that keeps the envelope correct.
    """
    return secrets.token_hex(16)


def _now_iso() -> str:
    """ISO-8601 with milliseconds and a literal Z suffix.

    ``datetime.isoformat()`` gives microseconds and a ``+00:00`` offset, neither
    of which the conformance suite accepts, so the format is spelled out.
    """
    now = datetime.now(UTC)
    return f"{now:%Y-%m-%dT%H:%M:%S}.{now.microsecond // 1000:03d}Z"


def meta_for(request: Request) -> dict[str, str]:
    """Builds the ``meta`` object for the current request.

    ``requestId`` is the human-quotable support identifier; ``traceId`` is the
    32-hex key into Tempo (OBS4.7). Both are required on every response.
    """
    return {
        "requestId": getattr(request.state, "request_id", None) or new_request_id(),
        "timestamp": _now_iso(),
        "traceId": getattr(request.state, "trace_id", None) or new_trace_id(),
    }


def success(request: Request, status_code: int, data: Any) -> JSONResponse:
    """Renders the ``{success: true, data, meta}`` envelope."""
    return JSONResponse(
        status_code=status_code,
        content={"success": True, "data": data, "meta": meta_for(request)},
    )


def failure(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    details: Any = None,
) -> JSONResponse:
    """Renders the ``{success: false, error, meta}`` envelope."""
    error: dict[str, Any] = {"code": code, "message": message}
    if details is not None:
        error["details"] = details
    return JSONResponse(
        status_code=status_code,
        content={"success": False, "error": error, "meta": meta_for(request)},
    )


def not_implemented(request: Request) -> JSONResponse:
    """The placeholder for every ``/api/v1`` route that is not built yet.

    It exists so the conformance suite fails loudly and specifically rather than
    returning a confusing 404.

    TODO(Phase 1): as each router is implemented, include it ABOVE the catch-all
    in ``app/main.py``. When this stops being reachable, Phase 1 is done.
    """
    return failure(
        request,
        501,
        "NOT_IMPLEMENTED",
        "Not implemented yet — see docs/learning-roadmap.md Phase 1",
    )
