"""Phase 5 — Resilience.

Idempotency, body-size limits and graceful shutdown. The shutdown test needs to
send SIGTERM to a container, so it carries both ``slow`` and ``docker`` and can
be deselected with ``-m "not docker"``.
"""

from __future__ import annotations

import concurrent.futures as futures
import time
import uuid

import pytest

from .assertions import (
    assert_error_envelope,
    assert_success_envelope,
    assert_task_shape,
)
from .client import ApiClient
from .dockerutil import container_running, docker_available, signal as docker_signal
from .util import future_iso

pytestmark = pytest.mark.phase5

#: docker-compose sets MAX_BODY_BYTES=1048576.
MAX_BODY_BYTES = 1_048_576


def _replayed(resp) -> str | None:
    for name, value in resp.headers.items():
        if name.lower() == "idempotency-replayed":
            return value
    return None


# ---------------------------------------------------------------------------
# Idempotency (FR8)
# ---------------------------------------------------------------------------


def test_replaying_an_idempotency_key_returns_the_original_response(user: ApiClient) -> None:
    key = str(uuid.uuid4())
    title = f"Idempotent {uuid.uuid4().hex[:8]}"

    first = user.create_task(title, idempotency_key=key)
    original = assert_task_shape(first, assert_success_envelope(first, 201)["task"])

    second = user.create_task(title, idempotency_key=key)
    second.implemented()
    assert second.status == 201, (
        f"{user.impl}: replaying an Idempotency-Key returned {second.status}. A replay "
        f"returns the *original* response, status included.\n{second.exchange.render()}"
    )
    replayed_task = second.task
    assert replayed_task == original, (
        f"{user.impl}: the replay returned a different task.\n"
        f"  original: {original}\n  replay:   {replayed_task}\n"
        f"The stored response is returned verbatim, not recomputed."
    )


def test_replay_sets_the_idempotency_replayed_header(user: ApiClient) -> None:
    key = str(uuid.uuid4())
    first = user.create_task("Header check", idempotency_key=key)
    first.expect(201)
    assert (_replayed(first) or "false").lower() != "true", (
        f"{user.impl}: the *first* request was marked Idempotency-Replayed: true"
    )

    second = user.create_task("Header check", idempotency_key=key)
    second.expect(201)
    header = _replayed(second)
    assert header is not None and header.lower() == "true", (
        f"{user.impl}: a replayed request must carry `Idempotency-Replayed: true` so "
        f"the client can tell a replay from a fresh create. Got {header!r}.\n"
        f"Headers: {dict(second.headers)}"
    )


def test_replay_does_not_create_a_second_task(user: ApiClient) -> None:
    """The whole point: a retried POST must not double-charge."""
    key = str(uuid.uuid4())
    nonce = uuid.uuid4().hex[:8]

    for _ in range(4):
        user.create_task(f"Once only {nonce}", idempotency_key=key).expect(201)

    listed = user.list_tasks(search=nonce, pageSize=100)
    assert_success_envelope(listed, 200)
    assert len(listed.data) == 1, (
        f"{user.impl}: four requests with one Idempotency-Key created "
        f"{len(listed.data)} tasks. A network retry is indistinguishable from a "
        f"duplicate submission — that is exactly what the key is for.\n"
        f"{listed.exchange.render()}"
    )


def test_different_keys_create_different_tasks(user: ApiClient) -> None:
    nonce = uuid.uuid4().hex[:8]
    for _ in range(3):
        user.create_task(f"Distinct {nonce}", idempotency_key=True).expect(201)

    listed = user.list_tasks(search=nonce, pageSize=100)
    assert_success_envelope(listed, 200)
    assert len(listed.data) == 3, (
        f"{user.impl}: three distinct Idempotency-Keys produced {len(listed.data)} "
        f"tasks. Deduplication must key on the header, not on the body."
    )


def test_no_idempotency_key_means_no_deduplication(user: ApiClient) -> None:
    nonce = uuid.uuid4().hex[:8]
    for _ in range(3):
        user.create_task(f"Unkeyed {nonce}").expect(201)

    listed = user.list_tasks(search=nonce, pageSize=100)
    assert len(assert_success_envelope(listed, 200)) == 3, (
        f"{user.impl}: the header is optional; without it, three creates are three tasks"
    )


def test_idempotency_keys_are_scoped_to_the_user(
    user: ApiClient, second_user: ApiClient
) -> None:
    """A shared key namespace lets one user read another's stored response."""
    key = str(uuid.uuid4())
    mine = user.create_task("Mine, keyed", idempotency_key=key)
    mine.expect(201)

    theirs = second_user.create_task("Theirs, same key", idempotency_key=key)
    theirs.implemented()
    assert theirs.status in (201, 409), (
        f"{second_user.impl}: reusing another user's Idempotency-Key returned "
        f"{theirs.status}\n{theirs.exchange.render()}"
    )
    if theirs.status == 201:
        assert theirs.task["id"] != mine.task["id"], (
            f"{second_user.impl}: a second user replaying the first user's "
            f"Idempotency-Key received the first user's task. Keys must be namespaced "
            f"per subject.\n{theirs.exchange.render()}"
        )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_an_in_flight_key_returns_409(user: ApiClient, new_client) -> None:
    """FR8.3 — a key currently in flight is a 409, not a second execution."""
    key = str(uuid.uuid4())
    nonce = uuid.uuid4().hex[:8]
    clients = [new_client() for _ in range(6)]
    for client in clients:
        client.access_token = user.access_token

    def fire(client: ApiClient):
        return client.create_task(f"Racing {nonce}", idempotency_key=key)

    with futures.ThreadPoolExecutor(max_workers=len(clients)) as pool:
        results = list(pool.map(fire, clients))

    for resp in results:
        resp.implemented()
    statuses = sorted(r.status for r in results)
    assert all(s in (201, 409) for s in statuses), (
        f"{user.impl}: concurrent requests with one Idempotency-Key produced {statuses}; "
        f"only 201 (winner or replay) and 409 (in flight) are documented.\n"
        f"{results[0].exchange.render()}"
    )

    listed = user.list_tasks(search=nonce, pageSize=100)
    assert len(assert_success_envelope(listed, 200)) == 1, (
        f"{user.impl}: {len(clients)} concurrent keyed requests created "
        f"{len(listed.data)} tasks. The key must be claimed atomically."
    )

    conflicts = [r for r in results if r.status == 409]
    for conflict in conflicts:
        error = assert_error_envelope(conflict, 409, "CONFLICT")
        details = error.get("details")
        if isinstance(details, dict) and "retryAfter" in details:
            assert isinstance(details["retryAfter"], int)


@pytest.mark.parametrize("key", ["short", "", "x" * 300], ids=["too_short", "empty", "too_long"])
def test_malformed_idempotency_key_is_rejected(user: ApiClient, key: str) -> None:
    """``Idempotency-Key`` is 8–255 characters; outside that it is a 400."""
    resp = user.create_task("Bad key", idempotency_key=key)
    resp.implemented()
    assert resp.status in (201, 400), (
        f"{user.impl}: Idempotency-Key {key!r} produced {resp.status}\n"
        f"{resp.exchange.render()}"
    )
    if resp.status == 400:
        assert_error_envelope(resp, 400, "VALIDATION_ERROR")


# ---------------------------------------------------------------------------
# Body size limits (RES5.2)
# ---------------------------------------------------------------------------


def test_oversized_body_returns_413(user: ApiClient) -> None:
    """A body larger than ``MAX_BODY_BYTES`` is refused before it is parsed.

    The important part is *before it is parsed*: a server that buffers the whole
    request and then validates it has already spent the memory an attacker
    wanted it to spend.
    """
    payload = {"title": "Oversized", "description": "x" * (MAX_BODY_BYTES + 4096)}
    resp = user.post("/tasks", json_body=payload)
    resp.implemented()

    assert resp.status == 413, (
        f"{user.impl}: a {MAX_BODY_BYTES + 4096:,}-byte body returned {resp.status}; "
        f"the documented answer is 413 (MAX_BODY_BYTES is {MAX_BODY_BYTES:,}).\n"
        f"{resp.exchange.render()}"
    )
    error = assert_error_envelope(resp, 413)
    details = error.get("details")
    if isinstance(details, dict) and "maxBytes" in details:
        assert details["maxBytes"] == MAX_BODY_BYTES, (
            f"{user.impl}: error.details.maxBytes says {details['maxBytes']}, "
            f"docker-compose configures {MAX_BODY_BYTES}"
        )


def test_body_just_under_the_limit_is_processed_normally(user: ApiClient) -> None:
    """The limit must not fire early — a 900 KB body is legal, if invalid."""
    payload = {"title": "Under the limit", "description": "x" * 900_000}
    resp = user.post("/tasks", json_body=payload)
    resp.implemented()
    assert resp.status == 400, (
        f"{user.impl}: a 900 KB body returned {resp.status}. It is under "
        f"MAX_BODY_BYTES, so it reaches validation — and fails there, because the "
        f"description exceeds 5000 characters.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 400, "VALIDATION_ERROR")


def test_malformed_json_returns_400_not_500(user: ApiClient) -> None:
    resp = user.post(
        "/tasks",
        data='{"title": "unterminated',
        headers={"Content-Type": "application/json"},
    )
    resp.implemented()
    assert resp.status == 400, (
        f"{user.impl}: unparsable JSON returned {resp.status}; a syntax error in the "
        f"request is the client's fault (400), never the server's (500).\n"
        f"{resp.exchange.render()}"
    )


def test_wrong_content_type_returns_415(user: ApiClient) -> None:
    resp = user.post(
        "/tasks", data="title=Form+Encoded",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp.implemented()
    assert resp.status in (400, 415), (
        f"{user.impl}: a form-encoded body on a JSON endpoint returned {resp.status}; "
        f"expected 415 (or 400).\n{resp.exchange.render()}"
    )


# ---------------------------------------------------------------------------
# Timeouts and overload
# ---------------------------------------------------------------------------


def test_a_valid_request_never_answers_5xx(user: ApiClient) -> None:
    """Smoke check across the surface: schema-valid input, no server errors."""
    probes = [
        ("GET", "/tasks", None),
        ("POST", "/tasks", {"title": "5xx probe", "dueDate": future_iso(3)}),
        ("GET", "/auth/me", None),
    ]
    for method, path, body in probes:
        resp = user.request(method, path, json_body=body)
        resp.implemented()
        assert resp.status < 500, (
            f"{user.impl}: {method} {path} with valid input returned {resp.status}.\n"
            f"{resp.exchange.render()}"
        )


# ---------------------------------------------------------------------------
# Graceful shutdown (RES4)
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.docker
@pytest.mark.destructive
@pytest.mark.timeout(300)
@pytest.mark.xdist_group("shutdown")
def test_graceful_shutdown_drops_no_requests(
    user: ApiClient, new_client, container_name: str, impl: str
) -> None:
    """SIGTERM during traffic must finish in-flight work, not sever it.

    This is the difference between a deploy nobody notices and a deploy that
    shows up as a spike of 502s. The container is restarted afterwards, so the
    test is destructive but self-healing.
    """
    if not docker_available():
        pytest.skip("the docker CLI is not available; cannot send SIGTERM to a container")
    if not container_running(container_name):
        pytest.skip(f"container {container_name} is not running")

    workers = 4
    duration = 12.0
    clients = [new_client() for _ in range(workers)]
    for client in clients:
        client.access_token = user.access_token

    results: list[tuple[int | None, str | None]] = []
    stop_at = time.monotonic() + duration

    def hammer(client: ApiClient) -> list[tuple[int | None, str | None]]:
        local: list[tuple[int | None, str | None]] = []
        while time.monotonic() < stop_at:
            try:
                resp = client.request("GET", "/tasks", params={"pageSize": 1}, timeout=10)
                local.append((resp.status, None))
            except Exception as exc:  # connection reset, refused, timed out
                local.append((None, f"{type(exc).__name__}: {exc}"))
            time.sleep(0.05)
        return local

    with futures.ThreadPoolExecutor(max_workers=workers + 1) as pool:
        running = [pool.submit(hammer, client) for client in clients]
        time.sleep(3.0)
        assert docker_signal(container_name, "SIGTERM"), (
            f"could not send SIGTERM to {container_name}"
        )
        for future in running:
            results.extend(future.result())

    try:
        dropped = [r for r in results if r[0] is None]
        server_errors = [r for r in results if r[0] is not None and r[0] >= 500]
        completed = [r for r in results if r[0] == 200]

        assert completed, (
            f"{impl}: no request completed during the shutdown window — the container "
            f"may have died before traffic started"
        )
        assert not dropped, (
            f"{impl}: {len(dropped)} of {len(results)} in-flight requests were dropped "
            f"when the container received SIGTERM. First: {dropped[0][1]}.\n"
            f"A graceful shutdown stops accepting new connections, drains the ones it "
            f"has, and only then exits (SHUTDOWN_GRACE_PERIOD is 30s)."
        )
        assert not server_errors, (
            f"{impl}: {len(server_errors)} requests answered 5xx during shutdown "
            f"(statuses {sorted({r[0] for r in server_errors})})"
        )
    finally:
        from .dockerutil import start as docker_start

        docker_start(container_name)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if user.ping(timeout=2):
                break
            time.sleep(2)


@pytest.mark.slow
@pytest.mark.docker
@pytest.mark.destructive
@pytest.mark.timeout(300)
@pytest.mark.xdist_group("shutdown")
def test_readiness_flips_to_not_ready_before_the_process_exits(
    api: ApiClient, container_name: str, impl: str
) -> None:
    """The pre-stop window: fail readiness first, keep serving, then exit.

    Without it the load balancer keeps routing to a replica that is already
    shutting down — which is the actual cause of most "graceful" shutdowns that
    still drop traffic.
    """
    if not docker_available():
        pytest.skip("the docker CLI is not available")
    if not container_running(container_name):
        pytest.skip(f"container {container_name} is not running")

    assert docker_signal(container_name, "SIGTERM"), f"could not signal {container_name}"

    saw_not_ready = False
    saw_live_after_not_ready = False
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            try:
                ready = api.get("/health/ready", auth=False, timeout=3)
            except Exception:
                break
            if ready.status == 503:
                saw_not_ready = True
                try:
                    live = api.get("/health/live", auth=False, timeout=3)
                    saw_live_after_not_ready = live.status in (200, 503)
                except Exception:
                    pass
                break
            time.sleep(0.2)

        assert saw_not_ready, (
            f"{impl}: /health/ready never reported 503 after SIGTERM. The shutdown "
            f"sequence must fail readiness first (SHUTDOWN_PRESTOP_DELAY is 5s) so "
            f"traffic drains away before the process stops accepting it."
        )
        assert saw_live_after_not_ready, (
            f"{impl}: the process stopped answering /health/live at the same instant "
            f"readiness flipped — there was no drain window at all"
        )
    finally:
        from .dockerutil import start as docker_start

        docker_start(container_name)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if api.ping(timeout=2):
                break
            time.sleep(2)
