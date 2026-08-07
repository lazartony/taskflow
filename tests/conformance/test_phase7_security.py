"""Phase 7 — Security Hardening.

Four things, in rough order of how often they are got wrong:

1. Security headers on *every* response, including errors.
2. Refresh-token rotation with **family revocation** — reusing a rotated token
   must kill every sibling, not just the one presented.
3. Login timing that does not distinguish "no such user" from "wrong password".
4. Error bodies that contain no stack trace, no SQL and no file paths.

The timing test is slow by construction: it needs 60 login attempts and
``/auth/*`` is limited to 10/min, so it pauses when rate-limited. Deselect it
with ``-m "not slow"`` during day-to-day work.
"""

from __future__ import annotations

import time
import uuid

import pytest

from .assertions import (
    assert_error_envelope,
    assert_no_internals_leaked,
    assert_success_envelope,
)
from .client import VALID_PASSWORD, ApiClient
from .util import describe, median

pytestmark = pytest.mark.phase7

#: Resilience & security specification §SEC4 — required response headers.
REQUIRED_HEADERS: dict[str, str | None] = {
    "Strict-Transport-Security": "max-age=",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src",
    "Referrer-Policy": "no-referrer",
}

#: Headers that advertise the stack to anyone scanning for a known CVE.
FORBIDDEN_HEADERS = ("Server", "X-Powered-By", "X-AspNet-Version", "X-AspNetMvc-Version")

TIMING_SAMPLES = 30
TIMING_TOLERANCE = 0.30  # medians must be within 30% of each other


def _header(resp, name: str) -> str | None:
    for key, value in resp.headers.items():
        if key.lower() == name.lower():
            return value
    return None


# ---------------------------------------------------------------------------
# Security headers
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("header,expected", sorted(REQUIRED_HEADERS.items()))
def test_security_header_present_on_a_success_response(
    api: ApiClient, header: str, expected: str | None
) -> None:
    resp = api.get("/health/live", auth=False)
    resp.implemented()
    value = _header(resp, header)
    assert value is not None, (
        f"{api.impl}: {header} is missing. Present: {sorted(resp.headers)}\n"
        f"Security headers belong in middleware that runs for every response, not on "
        f"individual handlers."
    )
    if expected is not None:
        assert expected.lower() in value.lower(), (
            f"{api.impl}: {header} is {value!r}; expected it to contain {expected!r}"
        )


@pytest.mark.parametrize("header", sorted(REQUIRED_HEADERS))
def test_security_header_present_on_an_error_response(api: ApiClient, header: str) -> None:
    """The 401 path usually bypasses the middleware that sets these."""
    resp = api.get("/tasks", auth=False)
    resp.implemented()
    if resp.status < 400:
        pytest.skip("GET /tasks without a token did not error; nothing to inspect")
    assert _header(resp, header) is not None, (
        f"{api.impl}: {header} is missing from a {resp.status} response but present on "
        f"200s. The error path is short-circuiting the security middleware.\n"
        f"Headers: {sorted(resp.headers)}"
    )


@pytest.mark.parametrize("header", FORBIDDEN_HEADERS)
def test_stack_advertising_headers_are_absent(api: ApiClient, header: str) -> None:
    resp = api.get("/health/live", auth=False)
    resp.implemented()
    value = _header(resp, header)
    assert value is None, (
        f"{api.impl}: the {header} header advertises {value!r}. Free reconnaissance for "
        f"anyone scanning for a version with a known CVE — strip it in middleware."
    )


def test_no_stack_advertising_headers_on_errors(api: ApiClient) -> None:
    resp = api.get("/definitely-not-a-real-endpoint", auth=False)
    leaked = {h: _header(resp, h) for h in FORBIDDEN_HEADERS if _header(resp, h)}
    assert not leaked, (
        f"{api.impl}: the error path re-adds {leaked}. Framework defaults come back "
        f"whenever a request does not reach your handler."
    )


def test_error_responses_are_not_cacheable(api: ApiClient) -> None:
    """A cached 401 at a shared proxy locks out a user who has since logged in."""
    resp = api.get("/tasks", auth=False)
    resp.implemented()
    if resp.status < 400:
        pytest.skip("no error response to inspect")
    cache_control = (_header(resp, "Cache-Control") or "").lower()
    assert "no-store" in cache_control or "no-cache" in cache_control or not cache_control, (
        f"{api.impl}: an error response carries Cache-Control: {cache_control!r}"
    )


# ---------------------------------------------------------------------------
# CORS
# ---------------------------------------------------------------------------


def test_cors_preflight_allows_a_configured_origin(api: ApiClient) -> None:
    resp = api.request(
        "OPTIONS",
        "/tasks",
        auth=False,
        headers={
            "Origin": "http://localhost:3000",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization,content-type",
        },
    )
    if resp.status == 501:
        pytest.skip(f"{api.impl}: OPTIONS is not routed yet")
    allowed = _header(resp, "Access-Control-Allow-Origin")
    assert allowed is not None, (
        f"{api.impl}: no Access-Control-Allow-Origin on a preflight from a configured "
        f"origin (CORS_ORIGINS includes http://localhost:3000).\n{resp.exchange.render()}"
    )
    assert allowed in ("http://localhost:3000", "*")


def test_cors_preflight_refuses_an_unknown_origin(api: ApiClient) -> None:
    """A reflected origin is the same as no CORS policy at all."""
    resp = api.request(
        "OPTIONS",
        "/tasks",
        auth=False,
        headers={
            "Origin": "https://evil.example.com",
            "Access-Control-Request-Method": "GET",
        },
    )
    if resp.status == 501:
        pytest.skip(f"{api.impl}: OPTIONS is not routed yet")
    allowed = _header(resp, "Access-Control-Allow-Origin")
    assert allowed != "https://evil.example.com", (
        f"{api.impl}: the Origin header was reflected back verbatim. That allows any "
        f"site to make credentialed cross-origin calls — the allow-list must be checked, "
        f"not echoed."
    )
    if allowed == "*":
        credentials = _header(resp, "Access-Control-Allow-Credentials")
        assert (credentials or "").lower() != "true", (
            f"{api.impl}: Access-Control-Allow-Origin: * together with "
            f"Allow-Credentials: true is rejected by browsers and signals a "
            f"misconfigured policy"
        )


# ---------------------------------------------------------------------------
# Refresh-token rotation and family revocation
# ---------------------------------------------------------------------------


def test_a_rotated_refresh_token_stops_working(user: ApiClient) -> None:
    original = user.refresh_token
    rotated = user.refresh(original, remember=False)
    assert_success_envelope(rotated, 200)

    replay = user.refresh(original, remember=False)
    replay.implemented()
    assert replay.status == 401, (
        f"{user.impl}: a refresh token still worked after being rotated "
        f"({replay.status}). Rotation without invalidation is not rotation.\n"
        f"{replay.exchange.render()}"
    )


def test_reusing_a_rotated_token_revokes_the_whole_family(user: ApiClient) -> None:
    """SEC2 — reuse detection.

    A rotated refresh token that is presented again means one of two things: a
    buggy client, or an attacker replaying a stolen token. You cannot tell which,
    so you assume the worst and kill the family — including the token the
    legitimate holder is currently using.

    Sequence: R0 → R1 → R2 (R2 is live and valid), then replay R0. Afterwards R2
    must be dead too.
    """
    r0 = user.refresh_token

    first = user.refresh(r0, remember=False)
    assert_success_envelope(first, 200)
    r1 = first.tokens["refreshToken"]

    second = user.refresh(r1, remember=False)
    assert_success_envelope(second, 200)
    r2 = second.tokens["refreshToken"]

    # R2 is genuinely usable right now — establish that before the replay.
    probe = user.refresh(r2, remember=False)
    probe.implemented()
    assert probe.status == 200, (
        f"{user.impl}: the current refresh token was rejected before any reuse "
        f"happened ({probe.status}); the rest of this test cannot mean anything.\n"
        f"{probe.exchange.render()}"
    )
    r3 = probe.tokens["refreshToken"]

    replay = user.refresh(r0, remember=False)
    replay.implemented()
    assert replay.status == 401, (
        f"{user.impl}: replaying the long-rotated token R0 returned {replay.status}"
    )

    aftermath = user.refresh(r3, remember=False)
    aftermath.implemented()
    assert aftermath.status == 401, (
        f"{user.impl}: after R0 was replayed, the still-live token R3 returned "
        f"{aftermath.status}. Reuse of any token in a family must revoke the entire "
        f"family — otherwise an attacker who stole an old token simply keeps refreshing "
        f"alongside the victim.\n{aftermath.exchange.render()}"
    )


def test_a_revoked_family_does_not_affect_other_sessions(
    user: ApiClient, new_client
) -> None:
    """Revocation is per family, not per user — logging in again must still work."""
    other = new_client()
    login = other.login(user.email, VALID_PASSWORD)
    assert_success_envelope(login, 200)
    other_refresh = other.refresh_token

    r0 = user.refresh_token
    rotated = user.refresh(r0, remember=False)
    assert_success_envelope(rotated, 200)
    user.refresh(r0, remember=False)  # trigger reuse detection on family one

    survivor = other.refresh(other_refresh, remember=False)
    survivor.implemented()
    assert survivor.status == 200, (
        f"{user.impl}: revoking one token family logged out an unrelated session "
        f"({survivor.status}). A phone being compromised should not sign you out of "
        f"your laptop.\n{survivor.exchange.render()}"
    )


def test_a_refresh_token_from_another_user_is_rejected(
    user: ApiClient, second_user: ApiClient
) -> None:
    resp = user.refresh(second_user.refresh_token, remember=False)
    resp.implemented()
    assert resp.status in (200, 401), f"unexpected status {resp.status}"
    if resp.status == 200:
        me = user.get("/auth/me", token=resp.tokens["accessToken"])
        assert me.user["id"] == second_user.user["id"], (
            f"{user.impl}: a refresh token minted tokens for the wrong subject"
        )


# ---------------------------------------------------------------------------
# Login timing
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(900)
@pytest.mark.xdist_group("ratelimit")
def test_login_timing_does_not_reveal_whether_an_account_exists(
    api: ApiClient, new_client
) -> None:
    """The dummy-hash check.

    The obvious implementation returns early when no user matches, skipping the
    bcrypt comparison entirely. bcrypt at cost 12 takes ~250 ms; the early
    return takes ~1 ms. That difference is trivially measurable over the network
    and turns login into a user-enumeration endpoint. The fix is to verify
    against a fixed dummy hash when the user is absent.

    Sampled 30 times each and interleaved so that drift in the machine's load
    affects both arms equally.
    """
    client = new_client()
    email = ApiClient.unique_email("timing")
    registration = client.register(email=email)
    registration.implemented()
    if registration.status == 429:
        pytest.skip(f"{api.impl}: /auth is rate-limited right now; re-run this alone")
    registration.expect(201)

    unknown_email = ApiClient.unique_email("ghost")
    wrong_password_ms: list[float] = []
    unknown_email_ms: list[float] = []

    def attempt(address: str) -> float | None:
        resp = client.login(address, "DefinitelyWrong123", remember=False)
        resp.implemented()
        if resp.status == 429:
            wait = 5
            details = resp.error_details
            if isinstance(details, dict) and isinstance(details.get("retryAfter"), int):
                wait = min(details["retryAfter"] + 1, 65)
            time.sleep(wait)
            return None
        assert resp.status == 401, (
            f"{api.impl}: a failed login returned {resp.status}\n{resp.exchange.render()}"
        )
        return resp.elapsed_ms

    deadline = time.monotonic() + 780
    while (
        len(wrong_password_ms) < TIMING_SAMPLES or len(unknown_email_ms) < TIMING_SAMPLES
    ) and time.monotonic() < deadline:
        if len(wrong_password_ms) < TIMING_SAMPLES:
            if (value := attempt(email)) is not None:
                wrong_password_ms.append(value)
        if len(unknown_email_ms) < TIMING_SAMPLES:
            if (value := attempt(unknown_email)) is not None:
                unknown_email_ms.append(value)

    if len(wrong_password_ms) < 10 or len(unknown_email_ms) < 10:
        pytest.skip(
            f"{api.impl}: only collected {len(wrong_password_ms)}/"
            f"{len(unknown_email_ms)} samples before the deadline — the /auth rate "
            f"limit makes this test impractical alongside others. Run it on its own: "
            f"pytest -m phase7 -k timing --impl {api.impl}"
        )

    known_median = median(wrong_password_ms)
    unknown_median = median(unknown_email_ms)
    larger = max(known_median, unknown_median)
    smaller = min(known_median, unknown_median)
    ratio = (larger - smaller) / larger if larger else 0.0

    assert ratio <= TIMING_TOLERANCE, (
        f"{api.impl}: login timing distinguishes an unknown account from a wrong "
        f"password by {ratio * 100:.0f}% (tolerance {TIMING_TOLERANCE * 100:.0f}%).\n"
        f"  wrong password: {describe(wrong_password_ms)}\n"
        f"  unknown email : {describe(unknown_email_ms)}\n"
        f"When no user matches, verify the supplied password against a fixed dummy hash "
        f"so both paths spend the same time in bcrypt."
    )


# ---------------------------------------------------------------------------
# Error hygiene
# ---------------------------------------------------------------------------


HOSTILE_INPUTS = [
    ("sql_quote", {"title": "O'Brien'); DROP TABLE tasks;--"}),
    ("sql_union", {"title": "x' UNION SELECT password_hash FROM users--"}),
    ("null_byte", {"title": "null\x00byte"}),
    ("xss", {"title": "<script>alert(1)</script>"}),
    ("template", {"title": "${7*7}{{7*7}}"}),
    ("path", {"title": "../../etc/passwd"}),
    ("unicode", {"title": "🙈" * 50}),
    ("deep_nest", {"title": "nested", "description": {"a": {"b": {"c": 1}}}}),
]


@pytest.mark.parametrize("name,payload", HOSTILE_INPUTS, ids=[n for n, _ in HOSTILE_INPUTS])
def test_hostile_input_never_leaks_internals_or_500s(
    user: ApiClient, name: str, payload: dict
) -> None:
    resp = user.post("/tasks", json_body=payload)
    resp.implemented()
    assert resp.status < 500, (
        f"{user.impl}: {name} input produced {resp.status}. Hostile input is ordinary "
        f"input — it gets a 400, never a 500.\n{resp.exchange.render()}"
    )
    assert_no_internals_leaked(resp)


@pytest.mark.parametrize(
    "probe",
    [
        ("GET", "/tasks/'; DROP TABLE tasks;--", None),
        ("GET", "/tasks", {"sortBy": "id; DROP TABLE tasks"}),
        ("GET", "/tasks", {"status": "pending' OR '1'='1"}),
        ("GET", "/tasks", {"search": "%' OR 1=1--"}),
    ],
    ids=["path_injection", "sort_injection", "filter_injection", "search_injection"],
)
def test_injection_attempts_are_rejected_cleanly(user: ApiClient, probe) -> None:
    method, path, params = probe
    resp = user.request(method, path, params=params)
    resp.implemented()
    assert resp.status < 500, (
        f"{user.impl}: {params or path} produced {resp.status}. A 500 on an injection "
        f"probe usually means the input reached the SQL parser.\n{resp.exchange.render()}"
    )
    assert_no_internals_leaked(resp)

    still_there = user.list_tasks(pageSize=1)
    still_there.implemented()
    assert still_there.status in (200, 429), (
        f"{user.impl}: the tasks table stopped answering after an injection probe "
        f"({still_there.status})"
    )


def test_error_messages_do_not_echo_the_supplied_credentials(api: ApiClient) -> None:
    secret = f"Sup3rSecret-{uuid.uuid4().hex[:8]}"
    resp = api.login("nobody@example.com", secret, remember=False)
    resp.implemented()
    import json as _json

    assert secret not in _json.dumps(resp.body), (
        f"{api.impl}: the failed-login response echoes the submitted password. "
        f"It will end up in a log, a proxy trace or a bug report.\n"
        f"{resp.exchange.render()}"
    )


def test_not_found_errors_do_not_confirm_existence(
    user: ApiClient, second_user: ApiClient
) -> None:
    """Two 404s that differ in wording are still an enumeration oracle."""
    real_but_foreign = second_user.create_task("Someone else's").expect(201).task
    missing = user.get_task("tsk_definitelymissing000")
    foreign = user.get_task(real_but_foreign["id"])

    missing_error = assert_error_envelope(missing, 404, "NOT_FOUND")
    foreign_error = assert_error_envelope(foreign, 404, "NOT_FOUND")

    assert missing_error.get("message") == foreign_error.get("message"), (
        f"{user.impl}: a nonexistent task says {missing_error.get('message')!r} but "
        f"another user's task says {foreign_error.get('message')!r}. The difference "
        f"tells an attacker which IDs are real."
    )
