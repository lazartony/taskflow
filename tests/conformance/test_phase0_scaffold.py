"""Phase 0 — Foundation.

These tests pass against the *shipped skeleton*, today, before a single line of
business logic exists. They are the floor: if they go red, something structural
broke — the envelope, the health probes, the request identifiers.

They are deliberately lenient about the *contents* of the health payload
(``version``, ``uptimeSeconds``, ``services`` arrive with OBS5 in phase 2) and
strict about its *shape*: envelope, status codes, identifiers, media type.
"""

from __future__ import annotations

import datetime as dt

import pytest

from .assertions import (
    REQUEST_ID_RE,
    TIMESTAMP_RE,
    assert_error_envelope,
    assert_json_content_type,
    assert_meta,
    assert_success_envelope,
    assert_trace_id,
)
from .client import ApiClient

pytestmark = pytest.mark.phase0

HEALTH_ENDPOINTS = ["/health", "/health/live", "/health/ready", "/health/startup"]

# Routes that exist in the contract but are unbuilt in the skeleton. Once a
# phase implements one it stops returning 501 and these tests simply stop
# exercising the 501 path — phase 0 must stay green for the life of the project.
UNBUILT_ROUTES = [
    ("GET", "/tasks"),
    ("POST", "/auth/login"),
    ("GET", "/auth/me"),
]


# ---------------------------------------------------------------------------
# The three probes plus the alias (OBS5)
# ---------------------------------------------------------------------------


def test_liveness_returns_200_and_is_envelope_shaped(api: ApiClient) -> None:
    resp = api.get("/health/live", auth=False)
    data = assert_success_envelope(resp, 200)
    assert isinstance(data, dict), f"health/live data must be an object, got {data!r}"
    assert data.get("status") in ("alive", "shutting_down"), (
        f"{api.impl}: health/live data.status must be 'alive' or 'shutting_down', "
        f"got {data.get('status')!r}\n{resp.exchange.render()}"
    )


def test_liveness_reports_no_dependency_state(api: ApiClient) -> None:
    """A liveness probe that reports dependencies is one that gets you paged.

    OBS5.1: ``/health/live`` answers "is this process wedged" and nothing else.
    If it surfaces database/cache/broker state, someone will eventually wire the
    probe to it and a database blip will kill every replica at once.
    """
    resp = api.get("/health/live", auth=False)
    data = assert_success_envelope(resp, 200)
    forbidden = {"services", "checks", "dependencies", "database", "cache", "broker"}
    leaked = forbidden & set(data)
    assert not leaked, (
        f"{api.impl}: /health/live must not report dependency state, found {sorted(leaked)}. "
        f"Dependency checks belong on /health/ready (OBS5.1 vs OBS5.2).\n"
        f"{resp.exchange.render()}"
    )


def test_liveness_does_not_query_the_database(api: ApiClient, db) -> None:
    """OBS5.1, verified from the other side: no SQL is issued per liveness call.

    Measured through ``pg_stat_statements``. The bound is loose on purpose —
    another test running in parallel may legitimately move the counter — but an
    implementation that runs ``SELECT 1`` on every liveness probe moves it by
    one per request and fails clearly.
    """
    probes = 40
    fingerprint = "%SELECT 1%"
    try:
        before = db.scalar(
            "SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements WHERE query LIKE %s",
            (fingerprint,),
        )
    except Exception as exc:  # extension not loaded in this environment
        pytest.skip(f"pg_stat_statements unavailable ({exc}); cannot measure query counts")

    for _ in range(probes):
        api.get("/health/live", auth=False)

    after = db.scalar(
        "SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements WHERE query LIKE %s",
        (fingerprint,),
    )
    delta = int(after) - int(before)
    assert delta < probes // 2, (
        f"{api.impl}: {probes} liveness probes produced {delta} `SELECT 1` executions. "
        f"/health/live must not touch the database (OBS5.1)."
    )


def test_readiness_returns_200_with_the_database_up(api: ApiClient) -> None:
    resp = api.get("/health/ready", auth=False)
    if resp.status == 503:
        error = assert_error_envelope(resp, 503)
        pytest.fail(
            f"{api.impl}: /health/ready reports the service not ready "
            f"({error.get('message')!r}). Is Postgres up? "
            f"`docker compose up -d postgres`\n{resp.exchange.render()}"
        )
    data = assert_success_envelope(resp, 200)
    assert isinstance(data, dict), f"health/ready data must be an object, got {data!r}"
    assert data.get("status") in ("ready", "healthy", "degraded"), (
        f"{api.impl}: /health/ready data.status should say the service is usable, "
        f"got {data.get('status')!r}\n{resp.exchange.render()}"
    )


def test_startup_returns_200(api: ApiClient) -> None:
    resp = api.get("/health/startup", auth=False)
    data = assert_success_envelope(resp, 200)
    assert isinstance(data, dict), f"health/startup data must be an object, got {data!r}"
    assert data.get("status") in ("started", "starting"), (
        f"{api.impl}: /health/startup data.status must be 'started' or 'starting', "
        f"got {data.get('status')!r}\n{resp.exchange.render()}"
    )


def test_bare_health_is_an_alias_of_ready(api: ApiClient) -> None:
    """OBS5.5 — ``/api/v1/health`` is ``/health/ready`` under another name."""
    alias = api.get("/health", auth=False)
    ready = api.get("/health/ready", auth=False)
    alias.implemented()
    ready.implemented()

    assert alias.status == ready.status, (
        f"{api.impl}: /health returned {alias.status} but /health/ready returned "
        f"{ready.status}; they must be the same endpoint (OBS5.5).\n"
        f"{alias.exchange.render()}\n{ready.exchange.render()}"
    )
    alias_data = alias.data if isinstance(alias.data, dict) else alias.error
    ready_data = ready.data if isinstance(ready.data, dict) else ready.error
    assert isinstance(alias_data, dict) and isinstance(ready_data, dict)
    assert set(alias_data) == set(ready_data), (
        f"{api.impl}: /health and /health/ready returned different payload shapes "
        f"({sorted(set(alias_data))} vs {sorted(set(ready_data))}). "
        f"OBS5.5 makes them aliases, not siblings."
    )
    if "status" in alias_data and "status" in ready_data:
        assert alias_data["status"] == ready_data["status"]


@pytest.mark.parametrize("path", HEALTH_ENDPOINTS)
def test_health_endpoints_need_no_authentication(api: ApiClient, path: str) -> None:
    """A probe that needs a token is a probe that cannot run in Kubernetes."""
    resp = api.get(path, auth=False)
    resp.implemented()
    assert resp.status != 401, (
        f"{api.impl}: {path} demanded authentication. Health endpoints are "
        f"unauthenticated by contract.\n{resp.exchange.render()}"
    )


# ---------------------------------------------------------------------------
# The envelope
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", HEALTH_ENDPOINTS)
def test_request_id_matches_the_documented_pattern(api: ApiClient, path: str) -> None:
    resp = api.get(path, auth=False)
    meta = assert_meta(resp)
    assert REQUEST_ID_RE.match(meta["requestId"])


def test_request_id_is_unique_per_request(api: ApiClient) -> None:
    ids = {assert_meta(api.get("/health/live", auth=False))["requestId"] for _ in range(5)}
    assert len(ids) == 5, (
        f"{api.impl}: meta.requestId repeated across requests ({sorted(ids)}). "
        f"It identifies one request, not the process."
    )


def test_request_id_header_matches_the_envelope(api: ApiClient) -> None:
    """If ``X-Request-Id`` is echoed it must agree with ``meta.requestId``."""
    resp = api.get("/health/live", auth=False)
    meta = assert_meta(resp)
    header = resp.headers.get("X-Request-Id") or resp.headers.get("X-Request-ID")
    if header is None:
        pytest.skip(f"{api.impl} does not echo X-Request-Id; the envelope value is authoritative")
    assert header == meta["requestId"], (
        f"{api.impl}: X-Request-Id header {header!r} disagrees with meta.requestId "
        f"{meta['requestId']!r}. Two different identifiers for one request is worse "
        f"than none.\n{resp.exchange.render()}"
    )


@pytest.mark.parametrize("path", HEALTH_ENDPOINTS)
def test_timestamp_is_iso8601_utc_with_milliseconds(api: ApiClient, path: str) -> None:
    resp = api.get(path, auth=False)
    meta = assert_meta(resp)
    assert TIMESTAMP_RE.match(meta["timestamp"]), meta["timestamp"]


def test_timestamp_is_actually_now(api: ApiClient) -> None:
    """Guards against a hard-coded or wrongly-offset clock."""
    resp = api.get("/health/live", auth=False)
    meta = assert_meta(resp)
    parsed = dt.datetime.strptime(meta["timestamp"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(
        tzinfo=dt.timezone.utc
    )
    skew = abs((dt.datetime.now(dt.timezone.utc) - parsed).total_seconds())
    assert skew < 300, (
        f"{api.impl}: meta.timestamp is {skew:.0f}s away from now ({meta['timestamp']}). "
        f"Either the clock is wrong or the value is not UTC."
    )


@pytest.mark.parametrize("path", HEALTH_ENDPOINTS)
def test_trace_id_is_32_lowercase_hex(api: ApiClient, path: str) -> None:
    """The envelope carries ``meta.traceId`` from day one (OBS4.7).

    Phase 0 only requires the *shape*; phase 2 requires it to be the real W3C
    trace ID from the active span.
    """
    assert_trace_id(api.get(path, auth=False))


@pytest.mark.parametrize("path", HEALTH_ENDPOINTS)
def test_content_type_is_json(api: ApiClient, path: str) -> None:
    assert_json_content_type(api.get(path, auth=False))


# ---------------------------------------------------------------------------
# The phase-0 contract for everything not yet built
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "method,path", UNBUILT_ROUTES, ids=[f"{m}{p}" for m, p in UNBUILT_ROUTES]
)
def test_unimplemented_routes_answer_501_in_the_error_envelope(
    api: ApiClient, method: str, path: str
) -> None:
    """Unbuilt routes must fail *loudly and specifically*, not with a 404.

    Once a phase implements the route this assertion falls through: the point is
    that there is never a moment where a route silently does not exist.
    """
    resp = api.request(method, path, auth=False)
    if resp.status != 501:
        # Implemented (or protected) — the phase-0 contract no longer applies.
        assert resp.status != 404, (
            f"{api.impl}: {method} {path} returned 404. An unbuilt route must return "
            f"501 NOT_IMPLEMENTED so the gap is obvious; a built one must not 404 on "
            f"its own collection path.\n{resp.exchange.render()}"
        )
        return
    error = assert_error_envelope(resp, 501, allow_501=True)
    assert error["code"] == "NOT_IMPLEMENTED", (
        f"{api.impl}: a 501 must carry error.code NOT_IMPLEMENTED, got "
        f"{error['code']!r}\n{resp.exchange.render()}"
    )
    assert_json_content_type(resp)


def test_error_responses_never_carry_a_success_envelope(api: ApiClient) -> None:
    """The envelope invariant: status >= 400 implies ``success: false``."""
    resp = api.get("/tasks", auth=False)
    if resp.status < 400:
        pytest.skip(f"{api.impl}: GET /tasks answered {resp.status}; nothing to check here")
    body = resp.json()
    assert body.get("success") is False, (
        f"{api.impl}: HTTP {resp.status} came back with success={body.get('success')!r}. "
        f"A >=400 status always carries success:false and an error object.\n"
        f"{resp.exchange.render()}"
    )
    assert "error" in body and isinstance(body["error"], dict)
    assert "data" not in body


def test_unknown_path_stays_inside_the_envelope(api: ApiClient) -> None:
    """Even a route nobody defined answers JSON, not an HTML error page."""
    resp = api.get("/definitely-not-a-real-endpoint", auth=False)
    assert resp.status >= 400, f"{api.impl}: an unknown path returned {resp.status}"
    assert_json_content_type(resp)
    body = resp.body
    assert isinstance(body, dict), (
        f"{api.impl}: an unknown path returned a non-JSON body — the framework's "
        f"default error page is leaking through.\n{resp.exchange.render()}"
    )
    assert body.get("success") is False
    assert isinstance(body.get("error"), dict)
    assert_meta(resp)


def test_the_openapi_version_prefix_is_honoured(api: ApiClient) -> None:
    """Everything lives under ``/api/v1``; the bare path must not also work."""
    unversioned = api.session.get(f"{api.base_url}/health/live", timeout=api.timeout)
    assert unversioned.status_code != 200 or "/api/v1" in unversioned.url, (
        f"{api.impl}: /health/live answered 200 outside the /api/v1 prefix. "
        f"Versioning that is optional is versioning that does not exist."
    )
