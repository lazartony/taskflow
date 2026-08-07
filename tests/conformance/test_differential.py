"""The differential test — send one scenario to all five, diff the answers.

This is the strongest check available to a project with five interchangeable
implementations of one spec, and it catches a class of bug that testing each
implementation in isolation cannot: **agreement**. Every implementation can pass
its own test suite and still disagree with the other four about whether
``dueDate`` ends in ``Z``, whether an omitted ``description`` is ``null`` or
absent, or whether ``pageSize`` is a number or a string.

What is compared
----------------
*Status code*, exactly. Then a **normalised** view of the JSON body:

* Volatile values (identifiers, timestamps, tokens, URLs, request and trace IDs)
  are replaced by a **shape signature**, not by their type name — a timestamp
  becomes ``<ts:9999-99-99T99:99:99.999Z>``, so ``2026-08-15T00:00:00`` and
  ``2026-08-15T00:00:00.000Z`` still compare unequal. Format divergence is
  precisely what this test exists to find.
* Everything else is compared by value: enum spellings, booleans, pagination
  arithmetic, error codes.

Runs only with ``--impl all``; anything narrower has nothing to diff.
"""

from __future__ import annotations

import json
import re
import uuid
from typing import Any, Callable

import pytest

from . import fakejwt
from .client import VALID_PASSWORD, ApiClient, NotImplementedYet, Response
from .util import future_iso, past_iso

pytestmark = [pytest.mark.phase1, pytest.mark.differential]

Step = tuple[str, Response]
Scenario = Callable[[ApiClient, dict], list[Step]]

#: Reference implementation for the diff. Any of the five would do; naming one
#: keeps failure messages stable and readable.
PREFERRED_REFERENCE = "go"

# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------

_TIMESTAMP_LIKE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")
_PREFIXED_ID = re.compile(r"^(usr|tsk|att|upl|req|evt)_[A-Za-z0-9._-]+$")
_JWT_LIKE = re.compile(r"^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*$")
_URL_LIKE = re.compile(r"^[a-z][a-z0-9+.-]*://", re.IGNORECASE)
_HEX32 = re.compile(r"^[0-9a-f]{32}$")

#: Keys whose *value* is legitimately free-form prose or environment-dependent.
#: The key must still be present with the same type in every implementation.
OPAQUE_KEYS = frozenset(
    {
        "message",
        "retryAfter",
        "uptimeSeconds",
        "version",
        "timestamp",
        "requestId",
        "traceId",
    }
)


def shape(value: Any, key: str | None = None) -> Any:
    """Reduce a value to what all five implementations must agree on."""
    if key in OPAQUE_KEYS:
        if isinstance(value, str) and _TIMESTAMP_LIKE.match(value):
            return _timestamp_signature(value)
        return f"<{type(value).__name__}>"

    if isinstance(value, dict):
        return {k: shape(v, k) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [shape(item) for item in value]
    if isinstance(value, bool) or value is None or isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        if _TIMESTAMP_LIKE.match(value):
            return _timestamp_signature(value)
        if _PREFIXED_ID.match(value):
            return f"<id:{value.split('_', 1)[0]}_…>"
        if _JWT_LIKE.match(value):
            return "<jwt>"
        if _URL_LIKE.match(value):
            return "<url>"
        if _HEX32.match(value):
            return "<hex32>"
        return value
    return f"<{type(value).__name__}>"


def _timestamp_signature(value: str) -> str:
    """``2026-08-15T00:00:00.000Z`` → ``<ts:9999-99-99T99:99:99.999Z>``.

    Keeps the *format* — separator, precision, offset spelling — and drops the
    instant. A missing ``Z`` or missing milliseconds still fails the diff.
    """
    return "<ts:" + re.sub(r"\d", "9", value) + ">"


def normalise(response: Response) -> dict:
    return {"status": response.status, "body": shape(response.body)}


# ---------------------------------------------------------------------------
# Diff rendering
# ---------------------------------------------------------------------------


def _flatten(obj: Any, prefix: str = "") -> dict[str, Any]:
    flat: dict[str, Any] = {}
    if isinstance(obj, dict):
        for key, value in obj.items():
            flat.update(_flatten(value, f"{prefix}.{key}" if prefix else key))
    elif isinstance(obj, list):
        for index, item in enumerate(obj):
            flat.update(_flatten(item, f"{prefix}[{index}]"))
    else:
        flat[prefix or "<root>"] = obj
    return flat


def _brief(value: Any, limit: int = 160) -> str:
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "…"


def render_divergence(label: str, reference_impl: str, reference: dict, impl: str, other: dict) -> str:
    """A field-by-field account of how one implementation differs."""
    lines = [f"  step {label!r}: {impl} diverges from {reference_impl}"]
    if reference["status"] != other["status"]:
        lines.append(
            f"    status: {reference_impl}={reference['status']}  {impl}={other['status']}"
        )

    left, right = _flatten(reference["body"]), _flatten(other["body"])
    differences = 0
    for path in sorted(set(left) | set(right)):
        a, b = left.get(path, "<absent>"), right.get(path, "<absent>")
        if a == b:
            continue
        differences += 1
        if differences > 20:
            lines.append(f"    … and {len(set(left) | set(right)) - 20} more fields")
            break
        lines.append(f"    {path}: {reference_impl}={_brief(a)}  {impl}={_brief(b)}")

    try:
        from deepdiff import DeepDiff  # type: ignore

        diff = DeepDiff(reference["body"], other["body"], verbose_level=2)
        if diff:
            rendered = diff.pretty() if hasattr(diff, "pretty") else str(diff)
            lines.append(f"    deepdiff: {rendered[:800]}")
    except Exception:
        pass
    return "\n".join(lines)


def _assert_identical(results: dict[str, list[Step]]) -> None:
    """Compare every implementation's run of one scenario against a reference."""
    impls = list(results)
    reference_impl = PREFERRED_REFERENCE if PREFERRED_REFERENCE in impls else impls[0]

    step_counts = {impl: len(steps) for impl, steps in results.items()}
    assert len(set(step_counts.values())) == 1, (
        f"the scenario produced a different number of steps per implementation: "
        f"{step_counts} — a step raised before completing"
    )

    labels = [label for label, _ in results[reference_impl]]
    problems: list[str] = []

    for index, label in enumerate(labels):
        reference = normalise(results[reference_impl][index][1])
        for impl in impls:
            if impl == reference_impl:
                continue
            other_label, other_resp = results[impl][index]
            assert other_label == label, (
                f"scenario steps ran out of order: {reference_impl} step {index} is "
                f"{label!r} but {impl} step {index} is {other_label!r}"
            )
            other = normalise(other_resp)
            if other != reference:
                problems.append(
                    render_divergence(label, reference_impl, reference, impl, other)
                )

    if problems:
        transcript = "\n".join(
            f"  [{impl}] {label}: HTTP {resp.status} {json.dumps(resp.body, default=str)[:300]}"
            for impl, steps in results.items()
            for label, resp in steps
        )
        pytest.fail(
            f"implementations disagree (reference: {reference_impl}).\n"
            + "\n".join(problems)
            + "\n\nfull exchange:\n"
            + transcript
        )


def _fresh(client: ApiClient) -> ApiClient:
    return ApiClient(client.base_url, client.impl)


def _run_everywhere(clients: dict[str, ApiClient], scenario: Scenario) -> dict[str, list[Step]]:
    """Run one scenario against every implementation with identical inputs.

    ``inputs`` is built once and shared, so any difference in the responses is a
    difference in the *servers*, not in what they were asked.
    """
    nonce = uuid.uuid4().hex[:10]
    inputs = {
        "nonce": nonce,
        "password": VALID_PASSWORD,
        "display_name": "Differential User",
        "title": f"Differential task {nonce}",
        "description": "A description that every implementation receives verbatim.",
        "due_date": future_iso(30),
        "past_date": past_iso(30),
        "updated_title": f"Differential updated {nonce}",
    }
    results: dict[str, list[Step]] = {}
    for impl, client in clients.items():
        # Per-implementation email: the five share one database in dev, so a
        # single address would make implementation two see a duplicate.
        scoped = dict(inputs, email=f"diff-{impl}-{nonce}@example.com")
        scoped["other_email"] = f"diff-{impl}-{nonce}-b@example.com"
        results[impl] = scenario(_fresh(client), scoped)
    return results


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------


def _register(client: ApiClient, inputs: dict) -> Response:
    return client.register(
        email=inputs["email"],
        password=inputs["password"],
        display_name=inputs["display_name"],
    )


def scenario_register(client: ApiClient, inputs: dict) -> list[Step]:
    return [("register", _register(client, inputs))]


def scenario_register_errors(client: ApiClient, inputs: dict) -> list[Step]:
    steps: list[Step] = [("register", _register(client, inputs))]
    steps.append(
        ("duplicate email", client.register(email=inputs["email"], remember=False))
    )
    steps.append(
        (
            "weak password",
            client.register(
                email=inputs["other_email"], password="weak", remember=False
            ),
        )
    )
    steps.append(
        ("invalid email", client.register(email="not-an-email", remember=False))
    )
    steps.append(
        (
            "display name too short",
            client.register(
                email=inputs["other_email"], display_name="A", remember=False
            ),
        )
    )
    steps.append(
        (
            "missing password",
            client.post(
                "/auth/register",
                json_body={"email": inputs["other_email"], "displayName": "No Password"},
                auth=False,
            ),
        )
    )
    return steps


def scenario_login(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    return [
        ("login", client.login(inputs["email"], inputs["password"])),
        (
            "wrong password",
            client.login(inputs["email"], "WrongPassword123", remember=False),
        ),
        (
            "unknown email",
            client.login(inputs["other_email"], inputs["password"], remember=False),
        ),
        (
            "missing password field",
            client.post("/auth/login", json_body={"email": inputs["email"]}, auth=False),
        ),
    ]


def scenario_auth_failures(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    real_token = client.access_token
    return [
        ("no token", client.get("/auth/me", auth=False)),
        ("malformed token", client.get("/auth/me", token="not-a-token")),
        ("alg none", client.get("/auth/me", token=fakejwt.alg_none_from(real_token))),
        (
            "wrong secret",
            client.get("/auth/me", token=fakejwt.resigned_with_wrong_secret(real_token)),
        ),
        (
            "wrong scheme",
            client.get("/auth/me", auth=False, headers={"Authorization": "Basic abc"}),
        ),
    ]


def scenario_list_empty(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    return [
        ("empty list", client.list_tasks()),
        ("empty list page 2", client.list_tasks(page=2)),
        ("empty list filtered", client.list_tasks(status="completed")),
    ]


def scenario_task_crud(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    steps: list[Step] = []

    minimal = client.create_task(inputs["title"])
    steps.append(("create minimal", minimal))

    full = client.create_task(
        f"{inputs['title']} full",
        description=inputs["description"],
        status="in_progress",
        priority="urgent",
        dueDate=inputs["due_date"],
    )
    steps.append(("create full", full))

    task_id = full.task["id"] if isinstance(full.task, dict) else "tsk_missing"
    steps.append(("get", client.get_task(task_id)))
    steps.append(("list", client.list_tasks(pageSize=20)))
    steps.append(("update title", client.update_task(task_id, title=inputs["updated_title"])))
    steps.append(("complete", client.update_task(task_id, status="completed")))
    steps.append(("reopen", client.update_task(task_id, status="pending")))
    steps.append(("delete", client.delete_task(task_id)))
    steps.append(("get after delete", client.get_task(task_id)))
    return steps


def scenario_task_validation(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    return [
        ("empty title", client.create_task("")),
        ("title too long", client.create_task("T" * 201)),
        (
            "description too long",
            client.create_task(inputs["title"], description="d" * 5001),
        ),
        ("past due date", client.create_task(inputs["title"], dueDate=inputs["past_date"])),
        ("bad status", client.create_task(inputs["title"], status="done")),
        ("bad priority", client.create_task(inputs["title"], priority="critical")),
        ("missing title", client.post("/tasks", json_body={"description": "no title"})),
        ("bad due date format", client.create_task(inputs["title"], dueDate="tomorrow")),
    ]


def scenario_not_found(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    missing = "tsk_doesnotexist000000000"
    return [
        ("get missing", client.get_task(missing)),
        ("update missing", client.update_task(missing, title="Ghost")),
        ("delete missing", client.delete_task(missing)),
        ("malformed id", client.get_task("not-an-id")),
        ("unknown route", client.get("/no-such-endpoint")),
    ]


def scenario_ownership(client: ApiClient, inputs: dict) -> list[Step]:
    owner = _fresh(client)
    owner.register(
        email=inputs["other_email"],
        password=inputs["password"],
        display_name=inputs["display_name"],
    )
    victim_task = owner.create_task(f"{inputs['title']} owned")
    task_id = victim_task.task["id"] if isinstance(victim_task.task, dict) else "tsk_missing"

    _register(client, inputs)
    return [
        ("read another user's task", client.get_task(task_id)),
        ("update another user's task", client.update_task(task_id, title="Hijacked")),
        ("delete another user's task", client.delete_task(task_id)),
    ]


def scenario_pagination(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    for index in range(5):
        client.create_task(
            f"{inputs['title']} {index:02d}",
            priority=("low", "medium", "high", "urgent")[index % 4],
        )
    return [
        ("page 1 size 2", client.list_tasks(page=1, pageSize=2)),
        ("page 3 size 2", client.list_tasks(page=3, pageSize=2)),
        ("beyond the end", client.list_tasks(page=99, pageSize=2)),
        ("page zero", client.list_tasks(page=0)),
        ("negative page", client.list_tasks(page=-1)),
        ("page size over max", client.list_tasks(pageSize=500)),
        ("page size zero", client.list_tasks(pageSize=0)),
        ("non-integer page", client.list_tasks(page="abc")),
        ("unknown sort field", client.list_tasks(sortBy="title")),
        ("unknown sort order", client.list_tasks(sortOrder="ascending")),
        ("filter by status", client.list_tasks(status="pending", pageSize=100)),
    ]


def scenario_token_lifecycle(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    original_refresh = client.refresh_token
    steps: list[Step] = [("refresh", client.refresh(original_refresh))]
    steps.append(("replay rotated refresh", client.refresh(original_refresh, remember=False)))
    steps.append(("logout", client.logout(client.refresh_token)))
    steps.append(("refresh after logout", client.refresh(client.refresh_token, remember=False)))
    steps.append(("refresh with garbage", client.post(
        "/auth/refresh", json_body={"refreshToken": "garbage"}, auth=False
    )))
    return steps


def scenario_profile(client: ApiClient, inputs: dict) -> list[Step]:
    _register(client, inputs)
    return [
        ("me", client.me()),
        ("update display name", client.update_profile(displayName="Renamed Person")),
        ("set avatar", client.update_profile(avatarUrl="https://example.com/a.png")),
        ("clear avatar", client.update_profile(avatarUrl=None)),
        ("empty update", client.put("/auth/profile", json_body={})),
        ("bad display name", client.update_profile(displayName="A")),
    ]


def scenario_health(client: ApiClient, inputs: dict) -> list[Step]:
    return [
        ("live", client.get("/health/live", auth=False)),
        ("ready", client.get("/health/ready", auth=False)),
        ("startup", client.get("/health/startup", auth=False)),
        ("alias", client.get("/health", auth=False)),
    ]


SCENARIOS: dict[str, Scenario] = {
    "health": scenario_health,
    "register": scenario_register,
    "register_errors": scenario_register_errors,
    "login": scenario_login,
    "auth_failures": scenario_auth_failures,
    "list_empty": scenario_list_empty,
    "task_crud": scenario_task_crud,
    "task_validation": scenario_task_validation,
    "not_found": scenario_not_found,
    "ownership": scenario_ownership,
    "pagination": scenario_pagination,
    "token_lifecycle": scenario_token_lifecycle,
    "profile": scenario_profile,
}


# ---------------------------------------------------------------------------
# The test
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scenario_name", sorted(SCENARIOS), ids=sorted(SCENARIOS))
@pytest.mark.timeout(300)
def test_all_implementations_return_identical_shapes(
    all_impl_clients: dict[str, ApiClient], scenario_name: str
) -> None:
    """One scenario, five servers, one answer."""
    results = _run_everywhere(all_impl_clients, SCENARIOS[scenario_name])

    not_implemented = sorted(
        impl
        for impl, steps in results.items()
        if all(resp.is_not_implemented for _, resp in steps)
    )
    if not_implemented and len(not_implemented) == len(results):
        # Raised rather than `pytest.fail` so the reporter files this under
        # "not implemented" instead of "failing" — nothing has diverged, the
        # endpoints simply do not exist yet.
        raise NotImplementedYet(
            ", ".join(not_implemented),
            "SCENARIO",
            scenario_name,
            "every implementation answered 501 for this scenario",
        )

    _assert_identical(results)


@pytest.mark.timeout(120)
def test_error_envelope_key_sets_are_identical(
    all_impl_clients: dict[str, ApiClient]
) -> None:
    """A narrower, faster check aimed at the envelope itself.

    Error bodies are where implementations diverge most: one adds ``details:
    null``, another omits the key; one nests ``fields`` under ``errors``.
    """
    from .util import key_paths

    nonce = uuid.uuid4().hex[:10]
    shapes: dict[str, set[str]] = {}
    bodies: dict[str, Any] = {}
    for impl, client in all_impl_clients.items():
        probe = _fresh(client).post(
            "/auth/register",
            json_body={"email": f"bad-{nonce}", "password": "x", "displayName": "A"},
            auth=False,
        )
        shapes[impl] = key_paths(probe.body if isinstance(probe.body, dict) else {})
        bodies[impl] = probe.body

    reference_impl = PREFERRED_REFERENCE if PREFERRED_REFERENCE in shapes else next(iter(shapes))
    reference = shapes[reference_impl]
    problems = []
    for impl, paths in shapes.items():
        if impl == reference_impl or paths == reference:
            continue
        problems.append(
            f"  {impl}: missing {sorted(reference - paths)}, extra {sorted(paths - reference)}"
        )
    if problems:
        rendered = "\n".join(
            f"  [{impl}] {json.dumps(body, default=str)[:300]}" for impl, body in bodies.items()
        )
        pytest.fail(
            f"error envelope key sets diverge (reference: {reference_impl}):\n"
            + "\n".join(problems)
            + "\n\nbodies:\n"
            + rendered
        )


@pytest.mark.timeout(120)
def test_status_codes_agree_across_the_documented_error_surface(
    all_impl_clients: dict[str, ApiClient]
) -> None:
    """Status codes only — the fastest signal that two servers disagree."""
    nonce = uuid.uuid4().hex[:10]

    def probes(client: ApiClient) -> list[tuple[str, int]]:
        client.register(email=f"status-{client.impl}-{nonce}@example.com")
        checks: list[tuple[str, int]] = []
        for label, resp in (
            ("no token", client.get("/tasks", auth=False)),
            ("bad token", client.get("/tasks", token="nope")),
            ("missing task", client.get_task("tsk_missing000000")),
            ("empty title", client.create_task("")),
            ("bad enum", client.create_task("x", status="done")),
            ("page zero", client.list_tasks(page=0)),
            ("unknown route", client.get("/nope")),
            ("wrong method", client.request("PATCH", "/tasks")),
        ):
            checks.append((label, resp.status))
        return checks

    observed = {impl: dict(probes(_fresh(client))) for impl, client in all_impl_clients.items()}
    reference_impl = (
        PREFERRED_REFERENCE if PREFERRED_REFERENCE in observed else next(iter(observed))
    )
    reference = observed[reference_impl]

    problems = []
    for label in reference:
        codes = {impl: table.get(label) for impl, table in observed.items()}
        if len(set(codes.values())) > 1:
            problems.append(f"  {label}: {codes}")
    assert not problems, (
        "implementations return different status codes for identical requests:\n"
        + "\n".join(problems)
    )
