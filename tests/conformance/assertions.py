"""Envelope assertions shared by every phase.

These encode the normative envelope from ``docs/openapi.yaml`` (``SuccessMeta``,
``ErrorResponse``, ``PaginationMeta``). Every one of them prints the offending
exchange on failure — the suite is a teaching tool first and a gate second.
"""

from __future__ import annotations

import re
from typing import Any

from .client import Response

REQUEST_ID_RE = re.compile(r"^req_[a-zA-Z0-9]+$")
TRACE_ID_RE = re.compile(r"^[0-9a-f]{32}$")
SPAN_ID_RE = re.compile(r"^[0-9a-f]{16}$")
# ISO-8601, UTC, millisecond precision, literal Z. Not "roughly ISO" — exactly
# this, or Go and C# will quietly disagree and every client has to cope.
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
USER_ID_RE = re.compile(r"^usr_[a-zA-Z0-9]{1,36}$")
TASK_ID_RE = re.compile(r"^tsk_[a-zA-Z0-9]{1,36}$")
ATTACHMENT_ID_RE = re.compile(r"^att_[a-zA-Z0-9]{1,36}$")
UPLOAD_ID_RE = re.compile(r"^upl_[a-zA-Z0-9]{1,36}$")
TRACEPARENT_RE = re.compile(r"^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$")

ERROR_CODES = {
    "VALIDATION_ERROR",
    "INVALID_CREDENTIALS",
    "UNAUTHORIZED",
    "FORBIDDEN",
    "NOT_FOUND",
    "CONFLICT",
    "RATE_LIMIT_EXCEEDED",
    "INTERNAL_ERROR",
    "GATEWAY_TIMEOUT",
    "SERVICE_OVERLOADED",
}

TASK_KEYS = {
    "id",
    "title",
    "description",
    "status",
    "priority",
    "dueDate",
    "completedAt",
    "createdAt",
    "updatedAt",
}
USER_KEYS = {"id", "email", "displayName", "avatarUrl", "createdAt", "updatedAt"}
TOKEN_KEYS = {"accessToken", "refreshToken", "expiresIn"}
PAGINATION_KEYS = {"page", "pageSize", "totalItems", "totalPages", "hasNext", "hasPrev"}
ATTACHMENT_KEYS = {"id", "taskId", "fileName", "fileSize", "mimeType", "url", "createdAt"}

TASK_STATUSES = ("pending", "in_progress", "completed", "archived")
TASK_PRIORITIES = ("low", "medium", "high", "urgent")


def _fail(resp: Response, message: str) -> None:
    raise AssertionError(f"{resp.impl}: {message}\n{resp.exchange.render()}")


# ---------------------------------------------------------------------------
# Envelope
# ---------------------------------------------------------------------------


def assert_json_content_type(resp: Response) -> None:
    ctype = resp.content_type.split(";")[0].strip().lower()
    if ctype != "application/json":
        _fail(resp, f"Content-Type must be application/json, got {resp.content_type!r}")


def assert_meta(resp: Response) -> dict:
    """Assert ``meta`` is present and well-formed. Returns it."""
    body = resp.body
    if not isinstance(body, dict):
        _fail(resp, f"response body is not a JSON object (got {type(body).__name__})")
    meta = body.get("meta")
    if not isinstance(meta, dict):
        _fail(resp, "every response must carry a `meta` object")

    request_id = meta.get("requestId")
    if not isinstance(request_id, str) or not REQUEST_ID_RE.match(request_id):
        _fail(resp, f"meta.requestId must match ^req_[a-zA-Z0-9]+$, got {request_id!r}")

    timestamp = meta.get("timestamp")
    if not isinstance(timestamp, str) or not TIMESTAMP_RE.match(timestamp):
        _fail(
            resp,
            "meta.timestamp must be ISO-8601 UTC with milliseconds and a Z "
            f"(e.g. 2026-08-07T12:34:56.789Z), got {timestamp!r}",
        )
    return meta


def assert_trace_id(resp: Response) -> str:
    """Assert ``meta.traceId`` is a W3C trace ID. Returns it."""
    meta = assert_meta(resp)
    trace_id = meta.get("traceId")
    if not isinstance(trace_id, str) or not TRACE_ID_RE.match(trace_id):
        _fail(
            resp,
            "meta.traceId must be 32 lowercase hex characters with no prefix, "
            f"got {trace_id!r}",
        )
    if trace_id == "0" * 32:
        _fail(resp, "meta.traceId is the all-zero (invalid) trace ID")
    return trace_id


def assert_success_envelope(resp: Response, status: int | None = None) -> Any:
    """Assert the ``{success:true, data, meta}`` shape. Returns ``data``."""
    resp.implemented()
    if status is not None and resp.status != status:
        _fail(resp, f"expected HTTP {status}, got {resp.status}")
    if resp.status >= 400:
        _fail(resp, f"expected a success status, got {resp.status}")
    assert_json_content_type(resp)
    body = resp.json()
    if body.get("success") is not True:
        _fail(resp, f"success envelope must have success: true, got {body.get('success')!r}")
    if "data" not in body:
        _fail(resp, "success envelope must have a `data` member")
    if "error" in body:
        _fail(resp, "a success envelope must not carry an `error` member")
    assert_meta(resp)
    return body["data"]


def assert_error_envelope(
    resp: Response,
    status: int | None = None,
    code: str | None = None,
    *,
    allow_501: bool = False,
) -> dict:
    """Assert the ``{success:false, error, meta}`` shape. Returns ``error``.

    ``allow_501`` is for the phase-0 test that asserts the *shape of a 501* —
    everywhere else a 501 means "not built yet" and must be reported as such.
    """
    if not allow_501:
        resp.implemented()
    if status is not None and resp.status != status:
        _fail(resp, f"expected HTTP {status}, got {resp.status}")
    assert_json_content_type(resp)
    body = resp.json()
    if body.get("success") is not False:
        _fail(resp, f"error envelope must have success: false, got {body.get('success')!r}")
    if "data" in body:
        _fail(resp, "an error envelope must not carry a `data` member")
    error = body.get("error")
    if not isinstance(error, dict):
        _fail(resp, "error envelope must have an `error` object")
    if not isinstance(error.get("code"), str) or not error["code"]:
        _fail(resp, f"error.code must be a non-empty string, got {error.get('code')!r}")
    if not isinstance(error.get("message"), str) or not error["message"]:
        _fail(resp, f"error.message must be a non-empty string, got {error.get('message')!r}")
    extra = set(error) - {"code", "message", "details"}
    if extra:
        _fail(resp, f"error object has undocumented keys: {sorted(extra)}")
    if code is not None and error["code"] != code:
        _fail(resp, f"expected error.code {code!r}, got {error['code']!r}")
    if code is not None and code in ERROR_CODES and error["code"] not in ERROR_CODES:
        _fail(resp, f"error.code {error['code']!r} is not in the documented enum")
    assert_meta(resp)
    return error


def assert_validation_error(resp: Response) -> dict:
    """400 + VALIDATION_ERROR, with a well-formed ``details.fields`` if present."""
    error = assert_error_envelope(resp, 400, "VALIDATION_ERROR")
    details = error.get("details")
    if isinstance(details, dict) and "fields" in details:
        fields = details["fields"]
        if not isinstance(fields, list) or not fields:
            _fail(resp, "error.details.fields must be a non-empty array when present")
        for entry in fields:
            if not isinstance(entry, dict) or "field" not in entry or "message" not in entry:
                _fail(resp, f"each details.fields entry needs `field` and `message`: {entry!r}")
    return error


# ---------------------------------------------------------------------------
# Domain resources
# ---------------------------------------------------------------------------


def assert_task_shape(resp: Response, task: Any) -> dict:
    if not isinstance(task, dict):
        _fail(resp, f"expected a task object, got {type(task).__name__}")
    keys = set(task)
    if keys != TASK_KEYS:
        missing = sorted(TASK_KEYS - keys)
        extra = sorted(keys - TASK_KEYS)
        _fail(
            resp,
            "task object key set does not match the contract "
            f"(missing={missing}, unexpected={extra}). Every optional value must be "
            "present and explicitly null, never omitted.",
        )
    if not TASK_ID_RE.match(str(task["id"])):
        _fail(resp, f"task.id must match ^tsk_[a-zA-Z0-9]{{1,36}}$, got {task['id']!r}")
    if task["status"] not in TASK_STATUSES:
        _fail(resp, f"task.status {task['status']!r} is not a documented enum value")
    if task["priority"] not in TASK_PRIORITIES:
        _fail(resp, f"task.priority {task['priority']!r} is not a documented enum value")
    for field in ("createdAt", "updatedAt"):
        if not isinstance(task[field], str) or not TIMESTAMP_RE.match(task[field]):
            _fail(
                resp,
                f"task.{field} must be ISO-8601 UTC with milliseconds and a Z, "
                f"got {task[field]!r}",
            )
    for field in ("dueDate", "completedAt"):
        value = task[field]
        if value is not None and (
            not isinstance(value, str) or not TIMESTAMP_RE.match(value)
        ):
            _fail(
                resp,
                f"task.{field} must be null or ISO-8601 UTC with milliseconds and a Z, "
                f"got {value!r}",
            )
    if task["description"] is not None and not isinstance(task["description"], str):
        _fail(resp, f"task.description must be a string or null, got {task['description']!r}")
    return task


def assert_user_shape(resp: Response, user: Any) -> dict:
    if not isinstance(user, dict):
        _fail(resp, f"expected a user object, got {type(user).__name__}")
    keys = set(user)
    if keys != USER_KEYS:
        _fail(
            resp,
            "user object key set does not match the contract "
            f"(missing={sorted(USER_KEYS - keys)}, unexpected={sorted(keys - USER_KEYS)})",
        )
    if not USER_ID_RE.match(str(user["id"])):
        _fail(resp, f"user.id must match ^usr_[a-zA-Z0-9]{{1,36}}$, got {user['id']!r}")
    for leaked in ("password", "passwordHash", "password_hash", "deletedAt", "deleted_at"):
        if leaked in user:
            _fail(resp, f"user object leaks {leaked!r} — it must never be serialised")
    return user


def assert_token_pair(resp: Response, tokens: Any) -> dict:
    if not isinstance(tokens, dict):
        _fail(resp, f"expected a tokens object, got {type(tokens).__name__}")
    if set(tokens) != TOKEN_KEYS:
        _fail(
            resp,
            "tokens key set does not match the contract "
            f"(missing={sorted(TOKEN_KEYS - set(tokens))}, "
            f"unexpected={sorted(set(tokens) - TOKEN_KEYS)})",
        )
    for field in ("accessToken", "refreshToken"):
        if not isinstance(tokens[field], str) or not tokens[field]:
            _fail(resp, f"tokens.{field} must be a non-empty string")
    if not isinstance(tokens["expiresIn"], int) or isinstance(tokens["expiresIn"], bool):
        _fail(resp, f"tokens.expiresIn must be an integer, got {tokens['expiresIn']!r}")
    if tokens["expiresIn"] <= 0:
        _fail(resp, f"tokens.expiresIn must be positive, got {tokens['expiresIn']}")
    return tokens


def assert_attachment_shape(resp: Response, attachment: Any) -> dict:
    if not isinstance(attachment, dict):
        _fail(resp, f"expected an attachment object, got {type(attachment).__name__}")
    if set(attachment) != ATTACHMENT_KEYS:
        _fail(
            resp,
            "attachment key set does not match the contract "
            f"(missing={sorted(ATTACHMENT_KEYS - set(attachment))}, "
            f"unexpected={sorted(set(attachment) - ATTACHMENT_KEYS)})",
        )
    if not ATTACHMENT_ID_RE.match(str(attachment["id"])):
        _fail(resp, f"attachment.id must match ^att_[a-zA-Z0-9]{{1,36}}$, got {attachment['id']!r}")
    if "/" in str(attachment["fileName"]) or "\\" in str(attachment["fileName"]):
        _fail(resp, f"attachment.fileName must not contain path separators: {attachment['fileName']!r}")
    return attachment


def assert_pagination(resp: Response, **expected: Any) -> dict:
    pagination = resp.pagination
    if not isinstance(pagination, dict):
        _fail(resp, "a list response must carry a `pagination` object beside `data`")
    if set(pagination) != PAGINATION_KEYS:
        _fail(
            resp,
            "pagination key set does not match the contract "
            f"(missing={sorted(PAGINATION_KEYS - set(pagination))}, "
            f"unexpected={sorted(set(pagination) - PAGINATION_KEYS)})",
        )
    for field in ("page", "pageSize", "totalItems", "totalPages"):
        value = pagination[field]
        if not isinstance(value, int) or isinstance(value, bool):
            _fail(resp, f"pagination.{field} must be an integer, got {value!r}")
    for field in ("hasNext", "hasPrev"):
        if not isinstance(pagination[field], bool):
            _fail(resp, f"pagination.{field} must be a boolean, got {pagination[field]!r}")

    # Internal consistency, independent of the expectations passed in.
    page, size = pagination["page"], pagination["pageSize"]
    total, pages = pagination["totalItems"], pagination["totalPages"]
    expected_pages = -(-total // size) if size else 0
    if pages != expected_pages:
        _fail(resp, f"pagination.totalPages must be ceil({total}/{size}) = {expected_pages}, got {pages}")
    if pagination["hasNext"] != (page < pages):
        _fail(resp, f"pagination.hasNext must be (page < totalPages) = {page < pages}, got {pagination['hasNext']}")
    if pagination["hasPrev"] != (page > 1):
        _fail(resp, f"pagination.hasPrev must be (page > 1) = {page > 1}, got {pagination['hasPrev']}")

    for key, want in expected.items():
        if pagination.get(key) != want:
            _fail(resp, f"pagination.{key}: expected {want!r}, got {pagination.get(key)!r}")
    return pagination


def assert_task_list(resp: Response) -> list:
    data = assert_success_envelope(resp, 200)
    if not isinstance(data, list):
        _fail(resp, f"GET /tasks must return `data` as a bare array, got {type(data).__name__}")
    for item in data:
        assert_task_shape(resp, item)
    assert_pagination(resp)
    return data


# ---------------------------------------------------------------------------
# Cross-cutting safety
# ---------------------------------------------------------------------------

_LEAK_PATTERNS = (
    re.compile(r"\bSELECT\b\s+.+\bFROM\b", re.IGNORECASE),
    re.compile(r"\bINSERT\s+INTO\b", re.IGNORECASE),
    re.compile(r"\bUPDATE\b\s+\w+\s+\bSET\b", re.IGNORECASE),
    re.compile(r"\bpg_\w+", re.IGNORECASE),
    re.compile(r"Traceback \(most recent call last\)"),
    re.compile(r"goroutine \d+ \[", re.IGNORECASE),
    re.compile(r"\bat [\w.$]+\([\w.]+\.(java|kt|cs|js|ts):\d+\)"),
    re.compile(r"panicked at ", re.IGNORECASE),
    re.compile(r"\bpanic:\s"),
    re.compile(r"\bStackTrace\b"),
    re.compile(r"System\.\w+Exception"),
    re.compile(r"\bat Object\.<anonymous>"),
    re.compile(r"/(usr|home|app|src|root)/[\w./-]+\.(go|rs|py|cs|ts|js):\d+"),
)


def assert_no_internals_leaked(resp: Response) -> None:
    """No stack trace, SQL fragment or source path in an error body (SEC)."""
    import json as _json

    text = _json.dumps(resp.body, default=str) if resp.body is not None else ""
    for pattern in _LEAK_PATTERNS:
        match = pattern.search(text)
        if match:
            _fail(
                resp,
                "error body leaks implementation internals "
                f"(matched {pattern.pattern!r} → {match.group(0)!r}). "
                "Errors must be generic; the detail belongs in the logs, keyed by "
                "meta.requestId.",
            )
