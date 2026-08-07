"""A tiny ``requests`` wrapper for talking to one TaskFlow implementation.

Design notes
------------
* Every exchange is recorded on the client so a failing assertion can print the
  request and response that produced it. A conformance failure that says only
  ``assert 400 == 201`` costs a learner twenty minutes; one that shows the JSON
  body costs thirty seconds.
* ``501 NOT_IMPLEMENTED`` is treated as a first-class outcome, not an error. The
  skeleton mounts :func:`httpx.NotImplemented` on every unbuilt route, so a
  learner running phase 4 tests on day one should be told "you have not built
  this yet", not shown a confusing assertion diff.
* Nothing here asserts. Assertions live in the tests; the client only reports.
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass
from typing import Any, Iterable, Mapping

import requests

API_PREFIX = "/api/v1"

#: Error code the shipped skeletons return from the catch-all handler.
NOT_IMPLEMENTED_CODE = "NOT_IMPLEMENTED"

#: A password that satisfies every rule in ``RegisterRequest.password``:
#: >= 8 chars, at least one lowercase, one uppercase and one digit.
VALID_PASSWORD = "SecurePass123"


#: Every 501 seen since the last reset, as ``(impl, method, url)``.
#:
#: The conftest clears this before each test and consults it when a test fails.
#: Not every assertion routes through :meth:`Response.implemented` — a test may
#: assert ``resp.status == 401`` directly — and without this the learner would
#: see "expected 401, got 501" rather than "you have not built this yet". This
#: list is what makes *unimplemented* an outcome instead of a puzzle.
NOT_IMPLEMENTED_SEEN: list[tuple[str, str, str]] = []


def reset_not_implemented() -> None:
    NOT_IMPLEMENTED_SEEN.clear()


class NotImplementedYet(AssertionError):
    """Raised when an endpoint answers ``501 NOT_IMPLEMENTED``.

    Subclasses :class:`AssertionError` so an un-caught one still fails the test
    (unimplemented must be *red*), but the conftest recognises the type and
    reports it as a distinct "not implemented yet" outcome.
    """

    def __init__(self, impl: str, method: str, path: str, message: str = "") -> None:
        self.impl = impl
        self.method = method
        self.path = path
        detail = f" — {message}" if message else ""
        super().__init__(
            f"{impl}: {method} {path} returned 501 NOT_IMPLEMENTED{detail}\n"
            f"This endpoint has not been built in the {impl} implementation yet. "
            f"That is the expected state before you start the phase."
        )


class Unreachable(Exception):
    """Raised when the target implementation cannot be contacted at all."""


@dataclass
class Exchange:
    """One request/response pair, kept for failure reporting."""

    impl: str
    method: str
    url: str
    request_headers: dict[str, str]
    request_body: Any
    status: int | None
    response_headers: dict[str, str]
    response_body: Any
    elapsed_ms: float
    error: str | None = None

    def render(self, max_body: int = 2000) -> str:
        def blob(value: Any) -> str:
            if value is None:
                return "<empty>"
            if isinstance(value, (dict, list)):
                text = json.dumps(value, indent=2, sort_keys=True, default=str)
            else:
                text = str(value)
            return text if len(text) <= max_body else text[:max_body] + "\n  … truncated"

        lines = [
            f"  → {self.method} {self.url}",
            f"    headers: {json.dumps(_redact(self.request_headers), default=str)}",
        ]
        if self.request_body is not None:
            lines.append(f"    body: {blob(self.request_body)}")
        if self.error is not None:
            lines.append(f"  ← TRANSPORT ERROR: {self.error}")
        else:
            lines.append(f"  ← {self.status} ({self.elapsed_ms:.0f} ms)")
            lines.append(f"    headers: {json.dumps(dict(self.response_headers), default=str)}")
            lines.append(f"    body: {blob(self.response_body)}")
        return "\n".join(lines)


def _redact(headers: Mapping[str, str]) -> dict[str, str]:
    out = {}
    for key, value in headers.items():
        if key.lower() == "authorization" and isinstance(value, str):
            out[key] = value[:16] + "…" if len(value) > 16 else value
        else:
            out[key] = value
    return out


class Response:
    """A thin view over :class:`requests.Response` that knows the envelope."""

    def __init__(self, impl: str, raw: requests.Response, exchange: Exchange) -> None:
        self.impl = impl
        self.raw = raw
        self.exchange = exchange

    # -- transport ---------------------------------------------------------

    @property
    def status(self) -> int:
        return self.raw.status_code

    @property
    def headers(self) -> Mapping[str, str]:
        return self.raw.headers

    @property
    def content_type(self) -> str:
        return self.raw.headers.get("Content-Type", "")

    @property
    def elapsed_ms(self) -> float:
        return self.exchange.elapsed_ms

    # -- envelope ----------------------------------------------------------

    @property
    def body(self) -> Any:
        """Parsed JSON body, or the raw text when the body is not JSON."""
        return self.exchange.response_body

    def json(self) -> dict:
        body = self.body
        if not isinstance(body, dict):
            raise AssertionError(
                f"{self.impl}: expected a JSON object body, got {type(body).__name__}\n"
                f"{self.exchange.render()}"
            )
        return body

    @property
    def success(self) -> Any:
        return self.body.get("success") if isinstance(self.body, dict) else None

    @property
    def data(self) -> Any:
        return self.body.get("data") if isinstance(self.body, dict) else None

    @property
    def pagination(self) -> Any:
        return self.body.get("pagination") if isinstance(self.body, dict) else None

    @property
    def meta(self) -> Any:
        return self.body.get("meta") if isinstance(self.body, dict) else None

    @property
    def error(self) -> Any:
        return self.body.get("error") if isinstance(self.body, dict) else None

    @property
    def error_code(self) -> str | None:
        err = self.error
        return err.get("code") if isinstance(err, dict) else None

    @property
    def error_details(self) -> Any:
        err = self.error
        return err.get("details") if isinstance(err, dict) else None

    # -- convenience -------------------------------------------------------

    @property
    def task(self) -> Any:
        return (self.data or {}).get("task") if isinstance(self.data, dict) else None

    @property
    def user(self) -> Any:
        return (self.data or {}).get("user") if isinstance(self.data, dict) else None

    @property
    def tokens(self) -> Any:
        return (self.data or {}).get("tokens") if isinstance(self.data, dict) else None

    @property
    def is_not_implemented(self) -> bool:
        return self.status == 501 or self.error_code == NOT_IMPLEMENTED_CODE

    # -- assertions the tests lean on --------------------------------------

    def implemented(self) -> "Response":
        """Return self, or raise :class:`NotImplementedYet` on a 501.

        Call this at the top of every test that exercises a route beyond phase
        0. It converts "you have not written this yet" into a specific,
        actionable message instead of a puzzling shape assertion.
        """
        if self.is_not_implemented:
            message = ""
            if isinstance(self.error, dict):
                message = self.error.get("message", "")
            raise NotImplementedYet(
                self.impl, self.exchange.method, self.exchange.url, message
            )
        return self

    def expect(self, status: int, code: str | None = None) -> "Response":
        """Assert the status (and optionally the error code), 501-aware."""
        self.implemented()
        if self.status != status:
            raise AssertionError(
                f"{self.impl}: expected HTTP {status}, got {self.status}\n"
                f"{self.exchange.render()}"
            )
        if code is not None and self.error_code != code:
            raise AssertionError(
                f"{self.impl}: expected error.code {code!r}, got {self.error_code!r}\n"
                f"{self.exchange.render()}"
            )
        return self

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<Response {self.impl} {self.exchange.method} {self.exchange.url} {self.status}>"


class ApiClient:
    """Client bound to a single implementation."""

    def __init__(
        self,
        base_url: str,
        impl: str,
        timeout: float = 10.0,
        session: requests.Session | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.impl = impl
        self.timeout = timeout
        self.session = session or requests.Session()
        self.access_token: str | None = None
        self.refresh_token: str | None = None
        self.user: dict | None = None
        self.exchanges: list[Exchange] = []

    # -- plumbing ----------------------------------------------------------

    def url_for(self, path: str) -> str:
        if path.startswith("http://") or path.startswith("https://"):
            return path
        if not path.startswith("/"):
            path = "/" + path
        if path.startswith(API_PREFIX):
            return self.base_url + path
        return self.base_url + API_PREFIX + path

    def request(
        self,
        method: str,
        path: str,
        *,
        json_body: Any = None,
        params: Mapping[str, Any] | None = None,
        headers: Mapping[str, str] | None = None,
        data: Any = None,
        files: Any = None,
        auth: bool = True,
        token: str | None = None,
        idempotency_key: str | bool | None = None,
        timeout: float | None = None,
    ) -> Response:
        url = self.url_for(path)
        hdrs: dict[str, str] = {"Accept": "application/json"}
        if auth:
            bearer = token if token is not None else self.access_token
            if bearer:
                hdrs["Authorization"] = f"Bearer {bearer}"
        if idempotency_key is True:
            hdrs["Idempotency-Key"] = str(uuid.uuid4())
        elif isinstance(idempotency_key, str):
            hdrs["Idempotency-Key"] = idempotency_key
        if headers:
            hdrs.update(headers)

        started = time.perf_counter()
        exchange = Exchange(
            impl=self.impl,
            method=method.upper(),
            url=url,
            request_headers=dict(hdrs),
            request_body=json_body if json_body is not None else data,
            status=None,
            response_headers={},
            response_body=None,
            elapsed_ms=0.0,
        )
        try:
            raw = self.session.request(
                method.upper(),
                url,
                json=json_body,
                params=dict(params) if params else None,
                headers=hdrs,
                data=data,
                files=files,
                timeout=timeout if timeout is not None else self.timeout,
                allow_redirects=False,
            )
        except requests.RequestException as exc:
            exchange.elapsed_ms = (time.perf_counter() - started) * 1000
            exchange.error = f"{type(exc).__name__}: {exc}"
            self.exchanges.append(exchange)
            raise Unreachable(
                f"{self.impl}-api not reachable at {url} — is it running? ({exc})"
            ) from exc

        exchange.elapsed_ms = (time.perf_counter() - started) * 1000
        exchange.status = raw.status_code
        exchange.response_headers = dict(raw.headers)
        try:
            exchange.response_body = raw.json()
        except ValueError:
            text = raw.text
            exchange.response_body = text if len(text) <= 4096 else text[:4096] + "…"
        self.exchanges.append(exchange)
        response = Response(self.impl, raw, exchange)
        if response.is_not_implemented:
            NOT_IMPLEMENTED_SEEN.append((self.impl, exchange.method, url))
        return response

    def get(self, path: str, **kw: Any) -> Response:
        return self.request("GET", path, **kw)

    def post(self, path: str, **kw: Any) -> Response:
        return self.request("POST", path, **kw)

    def put(self, path: str, **kw: Any) -> Response:
        return self.request("PUT", path, **kw)

    def delete(self, path: str, **kw: Any) -> Response:
        return self.request("DELETE", path, **kw)

    # -- reachability ------------------------------------------------------

    def ping(self, timeout: float = 2.0) -> bool:
        """True when the process answers its liveness probe."""
        try:
            resp = self.session.get(
                self.url_for("/health/live"), timeout=timeout, allow_redirects=False
            )
        except requests.RequestException:
            return False
        return resp.status_code < 500

    # -- auth helpers ------------------------------------------------------

    @staticmethod
    def unique_email(prefix: str = "conf") -> str:
        """A per-test unique address so the suite is safe under ``-n auto``."""
        return f"{prefix}-{uuid.uuid4().hex}@example.com"

    def register(
        self,
        email: str | None = None,
        password: str = VALID_PASSWORD,
        display_name: str = "Conformance User",
        *,
        remember: bool = True,
        idempotency_key: str | bool | None = None,
        **kw: Any,
    ) -> Response:
        payload = {
            "email": email if email is not None else self.unique_email(),
            "password": password,
            "displayName": display_name,
        }
        resp = self.post(
            "/auth/register",
            json_body=payload,
            auth=False,
            idempotency_key=idempotency_key,
            **kw,
        )
        if remember:
            self._remember(resp)
        return resp

    def login(
        self,
        email: str,
        password: str = VALID_PASSWORD,
        *,
        remember: bool = True,
        **kw: Any,
    ) -> Response:
        resp = self.post(
            "/auth/login", json_body={"email": email, "password": password}, auth=False, **kw
        )
        if remember:
            self._remember(resp)
        return resp

    def refresh(self, refresh_token: str | None = None, *, remember: bool = True, **kw: Any) -> Response:
        token = refresh_token if refresh_token is not None else self.refresh_token
        resp = self.post("/auth/refresh", json_body={"refreshToken": token}, auth=False, **kw)
        if remember:
            self._remember(resp)
        return resp

    def logout(self, refresh_token: str | None = None, **kw: Any) -> Response:
        token = refresh_token if refresh_token is not None else self.refresh_token
        return self.post("/auth/logout", json_body={"refreshToken": token}, **kw)

    def me(self, **kw: Any) -> Response:
        return self.get("/auth/me", **kw)

    def update_profile(self, **fields: Any) -> Response:
        request_kw = {k: fields.pop(k) for k in ("token", "auth", "headers") if k in fields}
        return self.put("/auth/profile", json_body=fields, **request_kw)

    def _remember(self, resp: Response) -> None:
        tokens = resp.tokens
        if isinstance(tokens, dict):
            self.access_token = tokens.get("accessToken") or self.access_token
            self.refresh_token = tokens.get("refreshToken") or self.refresh_token
        user = resp.user
        if isinstance(user, dict):
            self.user = user

    # -- task helpers ------------------------------------------------------

    def create_task(
        self,
        title: str = "Conformance task",
        *,
        idempotency_key: str | bool | None = None,
        **fields: Any,
    ) -> Response:
        request_kw = {k: fields.pop(k) for k in ("token", "auth", "headers") if k in fields}
        payload: dict[str, Any] = {"title": title}
        payload.update(fields)
        return self.post(
            "/tasks", json_body=payload, idempotency_key=idempotency_key, **request_kw
        )

    def list_tasks(self, **params: Any) -> Response:
        request_kw = {k: params.pop(k) for k in ("token", "auth", "headers") if k in params}
        clean = {k: v for k, v in params.items() if v is not None}
        return self.get("/tasks", params=clean, **request_kw)

    def get_task(self, task_id: str, **kw: Any) -> Response:
        return self.get(f"/tasks/{task_id}", **kw)

    def update_task(self, task_id: str, **fields: Any) -> Response:
        request_kw = {k: fields.pop(k) for k in ("token", "auth", "headers") if k in fields}
        return self.put(f"/tasks/{task_id}", json_body=fields, **request_kw)

    def delete_task(self, task_id: str, **kw: Any) -> Response:
        return self.delete(f"/tasks/{task_id}", **kw)

    # -- attachment helpers ------------------------------------------------

    def upload_attachment(
        self, task_id: str, filename: str, content: bytes, mime_type: str, **kw: Any
    ) -> Response:
        return self.post(
            f"/tasks/{task_id}/attachments",
            files={"file": (filename, content, mime_type)},
            **kw,
        )

    def list_attachments(self, task_id: str, **kw: Any) -> Response:
        return self.get(f"/tasks/{task_id}/attachments", **kw)

    def delete_attachment(self, task_id: str, attachment_id: str, **kw: Any) -> Response:
        return self.delete(f"/tasks/{task_id}/attachments/{attachment_id}", **kw)

    def presign_attachment(
        self, task_id: str, file_name: str, file_size: int, mime_type: str, **kw: Any
    ) -> Response:
        return self.post(
            f"/tasks/{task_id}/attachments/presign",
            json_body={"fileName": file_name, "fileSize": file_size, "mimeType": mime_type},
            **kw,
        )

    def complete_attachment(
        self,
        task_id: str,
        upload_id: str,
        file_name: str,
        file_size: int,
        mime_type: str,
        **kw: Any,
    ) -> Response:
        return self.post(
            f"/tasks/{task_id}/attachments/complete",
            json_body={
                "uploadId": upload_id,
                "fileName": file_name,
                "fileSize": file_size,
                "mimeType": mime_type,
            },
            **kw,
        )

    # -- reporting ---------------------------------------------------------

    def transcript(self, last: int = 4) -> str:
        """The last few exchanges, for pasting into a failure message."""
        if not self.exchanges:
            return f"  (no requests recorded for {self.impl})"
        return "\n".join(ex.render() for ex in self.exchanges[-last:])

    def reset_transcript(self) -> None:
        self.exchanges.clear()


def transcripts(clients: Iterable[ApiClient], last: int = 2) -> str:
    return "\n".join(f"[{c.impl}]\n{c.transcript(last)}" for c in clients)
