"""Hand-rolled JWTs for the negative auth tests.

Deliberately dependency-free — the suite must not need PyJWT, and forging a
token is six lines of base64. These helpers exist to produce tokens that a
correct server *rejects*:

* ``alg: none`` — the classic JWT vulnerability. A library that honours the
  header's algorithm field accepts an unsigned token as authentic.
* a token signed with the wrong secret — proves the signature is actually
  verified rather than the payload merely decoded.
* structurally broken tokens — proves the parser fails closed.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from typing import Any


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


def encode(header: dict[str, Any], payload: dict[str, Any], signature: bytes = b"") -> str:
    head = _b64url(json.dumps(header, separators=(",", ":"), sort_keys=True).encode())
    body = _b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    return f"{head}.{body}.{_b64url(signature)}"


def decode_payload(token: str) -> dict[str, Any]:
    """Best-effort payload decode. Returns ``{}`` for anything unparsable."""
    try:
        return json.loads(_b64url_decode(token.split(".")[1]))
    except Exception:
        return {}


def hs256(payload: dict[str, Any], secret: str, header: dict[str, Any] | None = None) -> str:
    head = header or {"alg": "HS256", "typ": "JWT"}
    head_b64 = _b64url(json.dumps(head, separators=(",", ":"), sort_keys=True).encode())
    body_b64 = _b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    signing_input = f"{head_b64}.{body_b64}".encode()
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return f"{head_b64}.{body_b64}.{_b64url(signature)}"


def alg_none(payload: dict[str, Any]) -> str:
    """An unsigned token claiming ``alg: none`` — must always be rejected."""
    return encode({"alg": "none", "typ": "JWT"}, payload, b"")


def alg_none_from(token: str) -> str:
    """Strip the signature off a real token, keeping its claims intact."""
    payload = decode_payload(token) or {"sub": "usr_forged"}
    return alg_none(payload)


def resigned_with_wrong_secret(token: str, secret: str = "an-entirely-different-secret-value") -> str:
    """Re-sign a real token's claims with a secret the server does not know."""
    payload = decode_payload(token) or {"sub": "usr_forged"}
    return hs256(payload, secret)


def tampered_payload(token: str, **claims: Any) -> str:
    """Keep the original signature but change the claims — must not verify."""
    parts = token.split(".")
    if len(parts) != 3:
        return token
    payload = decode_payload(token)
    payload.update(claims)
    body = _b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    return f"{parts[0]}.{body}.{parts[2]}"


#: Tokens that are not JWTs at all. Every one must produce 401, never 500.
MALFORMED_TOKENS: dict[str, str] = {
    "empty": "",
    "not_a_jwt": "this-is-not-a-token",
    "two_segments": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c3JfeCJ9",
    "four_segments": "a.b.c.d",
    "bad_base64": "!!!.???.###",
    "header_only": "eyJhbGciOiJIUzI1NiJ9..",
    "null_bytes": "abc\x00def.ghi.jkl",
    "very_long": "x" * 5000,
}
