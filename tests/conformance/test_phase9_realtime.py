"""Phase 9 — Real-Time at Scale.

The WebSocket endpoint is deliberately absent from ``paths`` in
``docs/openapi.yaml`` (OpenAPI cannot describe a bidirectional stream); its
contract lives under the root-level ``x-websocket`` extension, and this file is
its executable form.

Uses the synchronous client from ``websockets`` so the suite needs no async
plugin.
"""

from __future__ import annotations

import json
import time
import uuid
from contextlib import contextmanager

import pytest

from .assertions import TIMESTAMP_RE
from .client import ApiClient

pytestmark = pytest.mark.phase9

WS_PATH = "/api/v1/ws/events"
FRAME_WAIT_SECONDS = 10.0

#: ``x-websocket.eventTypes`` in the contract.
EVENT_TYPES = {
    "task.created",
    "task.updated",
    "task.deleted",
    "attachment.added",
    "attachment.removed",
}


def _ws_url(base_url: str, token: str | None) -> str:
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://")
    suffix = f"?token={token}" if token is not None else ""
    return f"{ws_base}{WS_PATH}{suffix}"


@contextmanager
def _connect(url: str, open_timeout: float = 10.0):
    ws_sync = pytest.importorskip(
        "websockets.sync.client",
        reason="websockets>=13 is required: pip install websockets",
    )
    connection = ws_sync.connect(url, open_timeout=open_timeout)
    try:
        yield connection
    finally:
        try:
            connection.close()
        except Exception:
            pass


def _skip_if_not_built(exc: Exception, impl: str) -> None:
    """A 501/404 handshake means the phase has not started — say so plainly."""
    text = str(exc)
    if "501" in text or "404" in text:
        pytest.fail(
            f"{impl}: the WebSocket handshake was rejected with "
            f"{'501' if '501' in text else '404'} — {WS_PATH} is not implemented yet "
            f"(phase 10).\n{text}"
        )


# ---------------------------------------------------------------------------
# Handshake and authentication
# ---------------------------------------------------------------------------


@pytest.mark.timeout(60)
def test_connects_with_a_valid_token(user: ApiClient, base_url: str) -> None:
    try:
        with _connect(_ws_url(base_url, user.access_token)) as ws:
            assert ws is not None
            # A connection that closes the instant it opens is not a connection.
            time.sleep(0.5)
            try:
                ws.send(json.dumps({"type": "ping"}))
            except Exception as exc:
                pytest.fail(
                    f"{user.impl}: the socket closed immediately after a successful "
                    f"handshake ({exc})"
                )
    except Exception as exc:
        _skip_if_not_built(exc, user.impl)
        pytest.fail(
            f"{user.impl}: could not open a WebSocket to {WS_PATH} with a valid access "
            f"token: {type(exc).__name__}: {exc}"
        )


@pytest.mark.timeout(60)
@pytest.mark.parametrize(
    "token", ["", "not-a-token", "a.b.c"], ids=["empty", "garbage", "fake_jwt"]
)
def test_rejects_an_invalid_token(user: ApiClient, base_url: str, token: str) -> None:
    """An unauthenticated socket is an authorisation bypass with a long lifetime."""
    try:
        with _connect(_ws_url(base_url, token), open_timeout=8.0) as ws:
            # Some servers accept the upgrade then close; give them a moment.
            time.sleep(1.0)
            try:
                message = ws.recv(timeout=3.0)
            except Exception:
                message = None
    except Exception:
        return  # handshake refused — the correct behaviour

    pytest.fail(
        f"{user.impl}: the WebSocket accepted token {token!r} and stayed open "
        f"(first frame: {message!r}). The token must be validated during the handshake "
        f"and the connection refused, not accepted and then policed."
    )


@pytest.mark.timeout(60)
def test_rejects_a_connection_with_no_token_at_all(user: ApiClient, base_url: str) -> None:
    try:
        with _connect(_ws_url(base_url, None), open_timeout=8.0) as ws:
            time.sleep(1.0)
            try:
                ws.recv(timeout=3.0)
            except Exception:
                pass
    except Exception:
        return
    pytest.fail(f"{user.impl}: {WS_PATH} accepted a connection with no token")


# ---------------------------------------------------------------------------
# Event fan-out
# ---------------------------------------------------------------------------


def _collect_frames(ws, seconds: float) -> list[dict]:
    frames: list[dict] = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            raw = ws.recv(timeout=max(0.2, deadline - time.monotonic()))
        except Exception:
            break
        try:
            frames.append(json.loads(raw))
        except (ValueError, TypeError):
            continue
    return frames


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_creating_a_task_over_http_produces_a_task_created_frame(
    user: ApiClient, base_url: str
) -> None:
    title = f"Realtime {uuid.uuid4().hex[:8]}"
    try:
        with _connect(_ws_url(base_url, user.access_token)) as ws:
            time.sleep(1.0)  # let the subscription settle before the write
            created = user.create_task(title)
            created.expect(201)
            task_id = created.task["id"]
            frames = _collect_frames(ws, FRAME_WAIT_SECONDS)
    except Exception as exc:
        _skip_if_not_built(exc, user.impl)
        pytest.fail(f"{user.impl}: WebSocket error: {type(exc).__name__}: {exc}")

    matches = [
        f
        for f in frames
        if f.get("type") == "task.created"
        and (f.get("data") or {}).get("id") == task_id
    ]
    assert matches, (
        f"{user.impl}: no `task.created` frame for {task_id} within "
        f"{FRAME_WAIT_SECONDS:.0f}s. Frames received: "
        f"{[f.get('type') for f in frames] or 'none'}"
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_the_frame_matches_the_documented_schema(user: ApiClient, base_url: str) -> None:
    """``x-websocket.serverMessages`` — ``{type, data, timestamp}``."""
    try:
        with _connect(_ws_url(base_url, user.access_token)) as ws:
            time.sleep(1.0)
            created = user.create_task(f"Frame schema {uuid.uuid4().hex[:8]}")
            created.expect(201)
            task_id = created.task["id"]
            frames = _collect_frames(ws, FRAME_WAIT_SECONDS)
    except Exception as exc:
        _skip_if_not_built(exc, user.impl)
        pytest.fail(f"{user.impl}: WebSocket error: {type(exc).__name__}: {exc}")

    matches = [f for f in frames if (f.get("data") or {}).get("id") == task_id]
    if not matches:
        pytest.fail(
            f"{user.impl}: no frame for {task_id}; types seen: "
            f"{[f.get('type') for f in frames]}"
        )
    frame = matches[0]

    missing = [key for key in ("type", "data", "timestamp") if key not in frame]
    assert not missing, (
        f"{user.impl}: the frame is missing {missing}. The contract is "
        f"{{type, data, timestamp}}.\n{json.dumps(frame, indent=2)[:800]}"
    )
    assert frame["type"] in EVENT_TYPES, (
        f"{user.impl}: frame type {frame['type']!r} is not one of the documented "
        f"event types {sorted(EVENT_TYPES)}"
    )
    assert TIMESTAMP_RE.match(str(frame["timestamp"])), (
        f"{user.impl}: frame timestamp {frame['timestamp']!r} is not ISO-8601 UTC with "
        f"milliseconds and a Z — the same format as meta.timestamp"
    )
    assert isinstance(frame["data"], dict) and frame["data"].get("id") == task_id


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_a_users_socket_never_receives_another_users_events(
    user: ApiClient, second_user: ApiClient, base_url: str
) -> None:
    """Fan-out must be scoped to the owner, exactly like every HTTP read."""
    try:
        with _connect(_ws_url(base_url, user.access_token)) as ws:
            time.sleep(1.0)
            foreign = second_user.create_task(f"Not yours {uuid.uuid4().hex[:8]}")
            foreign.expect(201)
            mine = user.create_task(f"Mine {uuid.uuid4().hex[:8]}")
            mine.expect(201)
            frames = _collect_frames(ws, FRAME_WAIT_SECONDS)
    except Exception as exc:
        _skip_if_not_built(exc, user.impl)
        pytest.fail(f"{user.impl}: WebSocket error: {type(exc).__name__}: {exc}")

    foreign_id = foreign.task["id"]
    leaked = [f for f in frames if (f.get("data") or {}).get("id") == foreign_id]
    assert not leaked, (
        f"{user.impl}: the socket delivered another user's task {foreign_id}. "
        f"Subscriptions must be keyed by the authenticated subject.\n"
        f"{json.dumps(leaked[0], indent=2)[:600]}"
    )
