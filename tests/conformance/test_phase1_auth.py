"""Phase 1 — Core API: authentication.

Covers registration validation, login, the token lifecycle and every way a
bearer token can be wrong. The rules come from ``RegisterRequest`` and the
``Unauthorized`` / ``InvalidCredentials`` responses in ``docs/openapi.yaml``.
"""

from __future__ import annotations

import pytest

from . import fakejwt
from .assertions import (
    assert_error_envelope,
    assert_no_internals_leaked,
    assert_success_envelope,
    assert_token_pair,
    assert_user_shape,
    assert_validation_error,
)
from .client import VALID_PASSWORD, ApiClient

pytestmark = pytest.mark.phase1


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


def test_register_returns_201_with_user_and_tokens(api: ApiClient) -> None:
    email = ApiClient.unique_email("reg")
    resp = api.register(email=email, display_name="Ada Lovelace")
    data = assert_success_envelope(resp, 201)

    assert set(data) == {"user", "tokens"}, (
        f"{api.impl}: register data must be exactly {{user, tokens}}, got {sorted(data)}\n"
        f"{resp.exchange.render()}"
    )
    user = assert_user_shape(resp, data["user"])
    assert_token_pair(resp, data["tokens"])
    assert user["email"] == email
    assert user["displayName"] == "Ada Lovelace"
    assert user["avatarUrl"] is None, "a new account has no avatar; the key is null, not absent"


def test_register_never_echoes_the_password(api: ApiClient) -> None:
    import json

    resp = api.register(password=VALID_PASSWORD)
    resp.expect(201)
    body = json.dumps(resp.body)
    assert VALID_PASSWORD not in body, (
        f"{api.impl}: the registration response contains the plaintext password.\n"
        f"{resp.exchange.render()}"
    )


def test_duplicate_email_returns_409_conflict(api: ApiClient) -> None:
    email = ApiClient.unique_email("dup")
    api.register(email=email).expect(201)

    second = api.register(email=email, remember=False)
    error = assert_error_envelope(second, 409, "CONFLICT")
    details = error.get("details")
    if isinstance(details, dict) and "conflictingField" in details:
        assert details["conflictingField"] == "email"
    assert_no_internals_leaked(second)


def test_duplicate_email_is_case_insensitive(api: ApiClient) -> None:
    """``User@Example.com`` and ``user@example.com`` are the same account."""
    email = ApiClient.unique_email("case")
    api.register(email=email).expect(201)
    resp = api.register(email=email.upper(), remember=False).implemented()
    assert resp.status == 409, (
        f"{api.impl}: registering {email.upper()} after {email} returned {resp.status}. "
        f"Email uniqueness must be case-insensitive or two people own one address.\n"
        f"{resp.exchange.render()}"
    )


@pytest.mark.parametrize(
    "password,rule",
    [
        ("Ab1", "shorter than the 8-character minimum"),
        ("Abc123", "6 characters, still under the minimum"),
        ("securepass123", "no uppercase letter"),
        ("SECUREPASS123", "no lowercase letter"),
        ("SecurePassword", "no digit"),
        ("", "empty"),
        ("A1b" + "!" * 130, "longer than the 128-character maximum"),
    ],
    ids=["too_short", "short_6", "no_upper", "no_lower", "no_digit", "empty", "too_long"],
)
def test_weak_password_rejected(api: ApiClient, password: str, rule: str) -> None:
    resp = api.register(password=password, remember=False)
    error = assert_validation_error(resp)
    assert_no_internals_leaked(resp)
    details = error.get("details")
    if isinstance(details, dict) and isinstance(details.get("fields"), list):
        fields = {entry.get("field") for entry in details["fields"]}
        assert "password" in fields, (
            f"{api.impl}: rejected a password that is {rule}, but details.fields names "
            f"{sorted(f for f in fields if f)} rather than 'password'.\n"
            f"{resp.exchange.render()}"
        )


def test_password_at_the_minimum_length_is_accepted(api: ApiClient) -> None:
    """Boundary: exactly 8 characters with one of each class must work."""
    resp = api.register(password="Abcdefg1", remember=False)
    assert_success_envelope(resp, 201)


@pytest.mark.parametrize(
    "email",
    ["not-an-email", "@example.com", "user@", "user example@test.com", "", "a@b"],
    ids=["no_at", "no_local", "no_domain", "space", "empty", "no_tld"],
)
def test_invalid_email_rejected(api: ApiClient, email: str) -> None:
    resp = api.register(email=email, remember=False)
    assert_validation_error(resp)


@pytest.mark.parametrize(
    "display_name,why",
    [("A", "1 character, below the 2-character minimum"), ("N" * 51, "51 characters, above the 50-character maximum")],
    ids=["one_char", "fifty_one_chars"],
)
def test_display_name_length_bounds(api: ApiClient, display_name: str, why: str) -> None:
    resp = api.register(display_name=display_name, remember=False)
    assert_validation_error(resp)


@pytest.mark.parametrize(
    "display_name", ["Ab", "N" * 50], ids=["two_chars", "fifty_chars"]
)
def test_display_name_at_the_bounds_is_accepted(api: ApiClient, display_name: str) -> None:
    resp = api.register(display_name=display_name, remember=False)
    assert_success_envelope(resp, 201)


@pytest.mark.parametrize(
    "payload",
    [
        {"password": VALID_PASSWORD, "displayName": "No Email"},
        {"email": "x@example.com", "displayName": "No Password"},
        {"email": "x@example.com", "password": VALID_PASSWORD},
        {},
    ],
    ids=["missing_email", "missing_password", "missing_display_name", "empty_body"],
)
def test_missing_required_fields_rejected(api: ApiClient, payload: dict) -> None:
    body = dict(payload)
    if "email" in body:
        body["email"] = ApiClient.unique_email("miss")
    resp = api.post("/auth/register", json_body=body, auth=False)
    assert_validation_error(resp)


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------


def test_login_returns_user_and_fresh_tokens(api: ApiClient) -> None:
    email = ApiClient.unique_email("login")
    registered = api.register(email=email)
    registered.expect(201)
    original_access = registered.tokens["accessToken"]

    resp = api.login(email, VALID_PASSWORD, remember=False)
    data = assert_success_envelope(resp, 200)
    assert set(data) == {"user", "tokens"}
    assert_user_shape(resp, data["user"])
    assert_token_pair(resp, data["tokens"])
    assert data["user"]["email"] == email
    assert data["tokens"]["accessToken"] != original_access, (
        f"{api.impl}: login returned the same access token as registration. "
        f"Each session must get its own token."
    )


def test_wrong_password_returns_401_invalid_credentials(api: ApiClient) -> None:
    email = ApiClient.unique_email("wrongpw")
    api.register(email=email).expect(201)
    resp = api.login(email, "CompletelyWrong123", remember=False)
    assert_error_envelope(resp, 401, "INVALID_CREDENTIALS")
    assert_no_internals_leaked(resp)


def test_unknown_email_and_wrong_password_are_indistinguishable(api: ApiClient) -> None:
    """The single most common auth information leak.

    If "no such user" and "wrong password" differ in *any* observable way — status,
    error code, message, key set — the endpoint becomes a user-enumeration oracle.
    """
    email = ApiClient.unique_email("enum")
    api.register(email=email).expect(201)

    wrong_password = api.login(email, "CompletelyWrong123", remember=False).implemented()
    unknown_email = api.login(
        ApiClient.unique_email("nobody"), VALID_PASSWORD, remember=False
    ).implemented()

    assert wrong_password.status == unknown_email.status, (
        f"{api.impl}: wrong password → {wrong_password.status}, unknown email → "
        f"{unknown_email.status}. Identical treatment or you have a user-enumeration "
        f"oracle.\n{wrong_password.exchange.render()}\n{unknown_email.exchange.render()}"
    )

    def strip_meta(body):
        return {k: v for k, v in body.items() if k != "meta"}

    left, right = strip_meta(wrong_password.json()), strip_meta(unknown_email.json())
    assert left == right, (
        f"{api.impl}: the two failure bodies differ.\n"
        f"  wrong password: {left}\n  unknown email : {right}\n"
        f"Everything outside `meta` must be byte-identical."
    )


@pytest.mark.parametrize(
    "payload",
    [{"password": VALID_PASSWORD}, {"email": "a@example.com"}, {}],
    ids=["missing_email", "missing_password", "empty"],
)
def test_login_missing_fields_rejected(api: ApiClient, payload: dict) -> None:
    assert_validation_error(api.post("/auth/login", json_body=payload, auth=False))


# ---------------------------------------------------------------------------
# Bearer token handling
# ---------------------------------------------------------------------------


def test_missing_token_returns_401_unauthorized(api: ApiClient) -> None:
    resp = api.get("/auth/me", auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_missing_token_on_tasks_returns_401_unauthorized(api: ApiClient) -> None:
    assert_error_envelope(api.get("/tasks", auth=False), 401, "UNAUTHORIZED")


# A null byte is not a legal HTTP field value (RFC 9110 §5.5), so most servers
# reject the request at the parsing layer before authentication ever runs. 400
# is a defensible answer there, and forcing 401 would mean fighting the HTTP
# stack in all five languages for no security benefit. Handled separately below.
_PROTOCOL_LEVEL_TOKENS = {"null_bytes"}


@pytest.mark.parametrize(
    "name", sorted(set(fakejwt.MALFORMED_TOKENS) - _PROTOCOL_LEVEL_TOKENS)
)
def test_malformed_token_returns_401(api: ApiClient, name: str) -> None:
    resp = api.get("/auth/me", token=fakejwt.MALFORMED_TOKENS[name]).implemented()
    assert resp.status == 401, (
        f"{api.impl}: a {name} token produced {resp.status}. Any unparsable token is "
        f"401 UNAUTHORIZED — never 400, never 500.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 401, "UNAUTHORIZED")
    assert_no_internals_leaked(resp)


@pytest.mark.parametrize("name", sorted(_PROTOCOL_LEVEL_TOKENS))
def test_protocol_illegal_token_is_rejected(api: ApiClient, name: str) -> None:
    """Rejected somewhere — the layer is the implementation's choice, but it
    must not be accepted and must not 500."""
    resp = api.get("/auth/me", token=fakejwt.MALFORMED_TOKENS[name]).implemented()
    assert resp.status in (400, 401), (
        f"{api.impl}: a {name} token produced {resp.status}. A token containing "
        f"bytes illegal in an HTTP header must be rejected with 400 (parsing "
        f"layer) or 401 (auth layer) — never accepted, never 500.\n"
        f"{resp.exchange.render()}"
    )
    assert_no_internals_leaked(resp)


@pytest.mark.parametrize(
    "header",
    ["Bearer", "Bearer  ", "Basic dXNlcjpwYXNz", "token abc.def.ghi", "bearer"],
    ids=["scheme_only", "scheme_and_space", "basic_auth", "wrong_scheme", "lowercase_no_token"],
)
def test_malformed_authorization_header_returns_401(api: ApiClient, header: str) -> None:
    resp = api.get("/auth/me", auth=False, headers={"Authorization": header})
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_alg_none_token_is_rejected(api: ApiClient, user: ApiClient) -> None:
    """CVE-class: honouring ``alg: none`` turns any claim set into a valid token."""
    forged = fakejwt.alg_none_from(user.access_token)
    resp = api.get("/auth/me", token=forged).implemented()
    assert resp.status == 401, (
        f"{api.impl}: an unsigned `alg: none` token was accepted ({resp.status}). "
        f"The verifier must pin the algorithm, not read it from the header.\n"
        f"{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_token_signed_with_a_different_secret_is_rejected(
    api: ApiClient, user: ApiClient
) -> None:
    forged = fakejwt.resigned_with_wrong_secret(user.access_token)
    resp = api.get("/auth/me", token=forged).implemented()
    assert resp.status == 401, (
        f"{api.impl}: a token signed with an unknown secret was accepted ({resp.status}). "
        f"The signature is not being verified.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_token_with_tampered_claims_is_rejected(api: ApiClient, user: ApiClient) -> None:
    forged = fakejwt.tampered_payload(user.access_token, sub="usr_someoneelse")
    resp = api.get("/auth/me", token=forged)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_expired_token_is_rejected(api: ApiClient, user: ApiClient) -> None:
    """Claims are checked, not just the signature.

    We cannot wait 15 minutes, so we forge a token whose ``exp`` is in the past.
    An implementation that verifies expiry rejects it for that reason; one that
    does not will still reject it for the signature — so this test asserts only
    what both must agree on, and never passes for the wrong reason.
    """
    payload = fakejwt.decode_payload(user.access_token)
    if "exp" not in payload:
        pytest.skip(f"{api.impl}: access token carries no `exp` claim to expire")
    payload["exp"] = 1_000_000_000  # 2001
    payload["iat"] = 999_999_000
    resp = api.get("/auth/me", token=fakejwt.hs256(payload, "not-the-real-secret"))
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------


def test_get_current_user(user: ApiClient) -> None:
    resp = user.me()
    data = assert_success_envelope(resp, 200)
    assert set(data) == {"user"}, f"GET /auth/me data must be {{user}}, got {sorted(data)}"
    me = assert_user_shape(resp, data["user"])
    assert me["email"] == user.email
    assert me["id"] == user.user["id"]


def test_update_profile_display_name(user: ApiClient) -> None:
    resp = user.update_profile(displayName="Renamed Person")
    data = assert_success_envelope(resp, 200)
    updated = assert_user_shape(resp, data["user"])
    assert updated["displayName"] == "Renamed Person"

    fetched = user.me()
    assert_success_envelope(fetched, 200)
    assert fetched.user["displayName"] == "Renamed Person", (
        f"{user.impl}: the profile update did not persist — GET /auth/me still returns "
        f"{fetched.user['displayName']!r}"
    )


def test_update_profile_avatar_url_and_clear_it(user: ApiClient) -> None:
    set_resp = user.update_profile(avatarUrl="https://example.com/avatar.png")
    assert_success_envelope(set_resp, 200)
    assert set_resp.user["avatarUrl"] == "https://example.com/avatar.png"

    clear_resp = user.update_profile(avatarUrl=None)
    assert_success_envelope(clear_resp, 200)
    assert clear_resp.user["avatarUrl"] is None, (
        f"{user.impl}: sending avatarUrl: null must clear the avatar, got "
        f"{clear_resp.user['avatarUrl']!r}"
    )


@pytest.mark.parametrize(
    "fields",
    [{"displayName": "A"}, {"displayName": "N" * 51}, {"avatarUrl": "not a url"}, {}],
    ids=["name_too_short", "name_too_long", "bad_url", "empty_body"],
)
def test_update_profile_validation(user: ApiClient, fields: dict) -> None:
    assert_validation_error(user.update_profile(**fields))


def test_update_profile_requires_authentication(api: ApiClient) -> None:
    resp = api.put("/auth/profile", json_body={"displayName": "Nope"}, auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


def test_profile_update_cannot_change_the_email_or_id(user: ApiClient) -> None:
    """``UpdateProfileRequest`` is a closed schema — extra keys are a 400."""
    original = dict(user.user)
    resp = user.put(
        "/auth/profile",
        json_body={"displayName": "Still Me", "email": "attacker@example.com"},
    )
    resp.implemented()
    if resp.status == 200:
        assert resp.user["email"] == original["email"], (
            f"{user.impl}: PUT /auth/profile changed the account's email. "
            f"Email is not a profile field.\n{resp.exchange.render()}"
        )
        assert resp.user["id"] == original["id"]
    else:
        assert_validation_error(resp)


# ---------------------------------------------------------------------------
# Token lifecycle
# ---------------------------------------------------------------------------


def test_refresh_issues_a_new_token_pair(user: ApiClient) -> None:
    old_access, old_refresh = user.access_token, user.refresh_token
    resp = user.refresh(old_refresh, remember=False)
    data = assert_success_envelope(resp, 200)
    assert set(data) == {"tokens"}, f"refresh data must be {{tokens}}, got {sorted(data)}"
    tokens = assert_token_pair(resp, data["tokens"])
    assert tokens["accessToken"] != old_access, (
        f"{user.impl}: refresh returned the same access token. Refresh must mint a new one."
    )
    assert tokens["refreshToken"] != old_refresh, (
        f"{user.impl}: refresh returned the same refresh token. Refresh tokens rotate "
        f"(SEC2) — reuse detection depends on it."
    )
    probe = user.get("/auth/me", token=tokens["accessToken"])
    assert_success_envelope(probe, 200)


@pytest.mark.parametrize(
    "token", ["", "not-a-token", "a.b.c"], ids=["empty", "garbage", "fake_jwt"]
)
def test_refresh_with_an_invalid_token_is_rejected(api: ApiClient, token: str) -> None:
    resp = api.post("/auth/refresh", json_body={"refreshToken": token}, auth=False)
    resp.implemented()
    assert resp.status in (400, 401), (
        f"{api.impl}: refreshing with {token!r} returned {resp.status}; expected 400 or 401.\n"
        f"{resp.exchange.render()}"
    )
    assert_error_envelope(resp, resp.status)


def test_refresh_rejects_an_access_token(user: ApiClient) -> None:
    """Access and refresh tokens are different token types, not interchangeable."""
    resp = user.refresh(user.access_token, remember=False)
    resp.implemented()
    assert resp.status in (400, 401), (
        f"{user.impl}: an access token was accepted at /auth/refresh ({resp.status}). "
        f"Token type must be part of what is verified.\n{resp.exchange.render()}"
    )


def test_logout_invalidates_the_refresh_token(user: ApiClient) -> None:
    refresh_token = user.refresh_token
    logout = user.logout(refresh_token)
    data = assert_success_envelope(logout, 200)
    assert set(data) == {"message"}, f"logout data must be {{message}}, got {sorted(data)}"

    replay = user.refresh(refresh_token, remember=False)
    replay.implemented()
    assert replay.status == 401, (
        f"{user.impl}: the refresh token still worked after logout ({replay.status}). "
        f"Logout that does not revoke is decoration.\n{replay.exchange.render()}"
    )


def test_logout_requires_authentication(api: ApiClient) -> None:
    resp = api.post("/auth/logout", json_body={"refreshToken": "whatever"}, auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")
