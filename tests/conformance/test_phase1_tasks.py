"""Phase 1 — Core API: task CRUD and ownership isolation.

The most important assertions in this file are the ownership ones. Returning
``403 Forbidden`` for another user's task confirms the resource exists, which
leaks the ID space. The contract says **404** — user B is told the task does not
exist, because as far as user B is concerned it does not.
"""

from __future__ import annotations

import pytest

from .assertions import (
    assert_error_envelope,
    assert_no_internals_leaked,
    assert_success_envelope,
    assert_task_shape,
    assert_validation_error,
)
from .client import ApiClient
from .util import future_iso, parse_iso, past_iso

pytestmark = pytest.mark.phase1

MISSING_TASK_ID = "tsk_doesnotexist000000000"


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


def test_create_task_applies_documented_defaults(user: ApiClient) -> None:
    resp = user.create_task("Minimal task")
    data = assert_success_envelope(resp, 201)
    assert set(data) == {"task"}, f"create data must be {{task}}, got {sorted(data)}"
    task = assert_task_shape(resp, data["task"])

    assert task["title"] == "Minimal task"
    assert task["status"] == "pending", (
        f"{user.impl}: a new task defaults to status 'pending', got {task['status']!r}"
    )
    assert task["priority"] == "medium", (
        f"{user.impl}: a new task defaults to priority 'medium', got {task['priority']!r}"
    )
    assert task["description"] is None, "an omitted description is null, not absent or ''"
    assert task["dueDate"] is None
    assert task["completedAt"] is None
    assert task["createdAt"] == task["updatedAt"], (
        f"{user.impl}: createdAt and updatedAt must match on a freshly created task "
        f"({task['createdAt']} vs {task['updatedAt']})"
    )


def test_create_task_with_every_field(user: ApiClient) -> None:
    due = future_iso(14)
    resp = user.create_task(
        "Full task",
        description="Every field populated",
        status="in_progress",
        priority="urgent",
        dueDate=due,
    )
    task = assert_task_shape(resp, assert_success_envelope(resp, 201)["task"])
    assert task["description"] == "Every field populated"
    assert task["status"] == "in_progress"
    assert task["priority"] == "urgent"
    assert parse_iso(task["dueDate"]) == parse_iso(due), (
        f"{user.impl}: dueDate round-tripped as {task['dueDate']!r}, sent {due!r}"
    )


@pytest.mark.parametrize(
    "status", ["pending", "in_progress", "completed", "archived"]
)
def test_create_task_accepts_every_status(user: ApiClient, status: str) -> None:
    resp = user.create_task(f"Status {status}", status=status)
    task = assert_task_shape(resp, assert_success_envelope(resp, 201)["task"])
    assert task["status"] == status


@pytest.mark.parametrize("priority", ["low", "medium", "high", "urgent"])
def test_create_task_accepts_every_priority(user: ApiClient, priority: str) -> None:
    resp = user.create_task(f"Priority {priority}", priority=priority)
    task = assert_task_shape(resp, assert_success_envelope(resp, 201)["task"])
    assert task["priority"] == priority


def test_create_task_requires_authentication(api: ApiClient) -> None:
    resp = api.post("/tasks", json_body={"title": "Anonymous"}, auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


# ---------------------------------------------------------------------------
# Create — validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "title,why",
    [("", "empty"), ("T" * 201, "201 characters, over the 200 maximum")],
    ids=["empty_title", "title_201_chars"],
)
def test_invalid_title_rejected(user: ApiClient, title: str, why: str) -> None:
    resp = user.create_task(title)
    assert_validation_error(resp)
    assert_no_internals_leaked(resp)


@pytest.mark.parametrize(
    "title", ["T", "T" * 200], ids=["title_1_char", "title_200_chars"]
)
def test_title_at_the_bounds_is_accepted(user: ApiClient, title: str) -> None:
    assert_success_envelope(user.create_task(title), 201)


def test_description_over_5000_chars_rejected(user: ApiClient) -> None:
    assert_validation_error(user.create_task("Long description", description="d" * 5001))


def test_description_of_exactly_5000_chars_is_accepted(user: ApiClient) -> None:
    resp = user.create_task("Boundary description", description="d" * 5000)
    assert_success_envelope(resp, 201)


def test_due_date_in_the_past_rejected(user: ApiClient) -> None:
    """A business rule JSON Schema cannot express — so it needs its own test."""
    resp = user.create_task("Overdue on arrival", dueDate=past_iso(1))
    assert_validation_error(resp)


def test_due_date_in_the_future_is_accepted(user: ApiClient) -> None:
    assert_success_envelope(user.create_task("Due soon", dueDate=future_iso(1)), 201)


@pytest.mark.parametrize(
    "field,value",
    [
        ("status", "done"),
        ("status", "PENDING"),
        ("status", ""),
        ("priority", "critical"),
        ("priority", "MEDIUM"),
        ("priority", 1),
    ],
    ids=["status_done", "status_upper", "status_empty", "priority_critical", "priority_upper", "priority_int"],
)
def test_invalid_enum_rejected(user: ApiClient, field: str, value: object) -> None:
    assert_validation_error(user.create_task("Bad enum", **{field: value}))


@pytest.mark.parametrize(
    "due", ["not-a-date", "2026-13-45T00:00:00Z", "1755000000", ""],
    ids=["garbage", "impossible", "epoch_seconds", "empty"],
)
def test_invalid_due_date_format_rejected(user: ApiClient, due: str) -> None:
    assert_validation_error(user.create_task("Bad date", dueDate=due))


def test_missing_title_rejected(user: ApiClient) -> None:
    assert_validation_error(user.post("/tasks", json_body={"description": "no title"}))


def test_unknown_field_rejected_or_ignored_consistently(user: ApiClient) -> None:
    """``CreateTaskRequest`` sets ``additionalProperties: false``.

    A 400 is the contract. An implementation that silently drops the field is
    accepted here only if it does not persist it — what must never happen is one
    of the five inventing a new response key.
    """
    resp = user.post("/tasks", json_body={"title": "Extra field", "userId": "usr_someoneelse"})
    resp.implemented()
    if resp.status == 201:
        assert_task_shape(resp, resp.task)
    else:
        assert_validation_error(resp)


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------


def test_get_task_by_id(user: ApiClient, task: dict) -> None:
    resp = user.get_task(task["id"])
    fetched = assert_task_shape(resp, assert_success_envelope(resp, 200)["task"])
    assert fetched == task, (
        f"{user.impl}: GET /tasks/{{id}} returned a different object than POST /tasks did.\n"
        f"  created: {task}\n  fetched: {fetched}"
    )


def test_get_nonexistent_task_returns_404(user: ApiClient) -> None:
    resp = user.get_task(MISSING_TASK_ID)
    error = assert_error_envelope(resp, 404, "NOT_FOUND")
    assert_no_internals_leaked(resp)
    details = error.get("details")
    if isinstance(details, dict) and "resource" in details:
        assert details["resource"] == "task"


def test_get_task_with_a_malformed_id(user: ApiClient) -> None:
    resp = user.get_task("not-a-task-id")
    resp.implemented()
    assert resp.status in (400, 404), (
        f"{user.impl}: a malformed task id produced {resp.status}; expected 400 or 404, "
        f"never a 500.\n{resp.exchange.render()}"
    )
    assert_no_internals_leaked(resp)


def test_list_returns_only_the_callers_tasks(user: ApiClient, second_user: ApiClient) -> None:
    mine = [user.create_task(f"Mine {i}").expect(201).task["id"] for i in range(3)]
    theirs = [second_user.create_task(f"Theirs {i}").expect(201).task["id"] for i in range(2)]

    resp = user.list_tasks(pageSize=100)
    data = assert_success_envelope(resp, 200)
    ids = {t["id"] for t in data}

    assert set(mine) <= ids, f"{user.impl}: the caller's own tasks are missing from the list"
    leaked = ids & set(theirs)
    assert not leaked, (
        f"{user.impl}: GET /tasks returned {len(leaked)} task(s) belonging to another "
        f"user ({sorted(leaked)}). Every query is scoped by the bearer token's subject.\n"
        f"{resp.exchange.render()}"
    )
    assert resp.pagination["totalItems"] == len(ids) or resp.pagination["totalItems"] >= 3


# ---------------------------------------------------------------------------
# Ownership isolation — 404, never 403
# ---------------------------------------------------------------------------


def test_get_another_users_task_returns_404_not_403(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Private").expect(201).task
    resp = user.get_task(victim_task["id"])
    resp.implemented()
    assert resp.status != 403, (
        f"{user.impl}: reading another user's task returned 403. A 403 confirms the "
        f"resource exists, which turns the ID space into an enumeration oracle. "
        f"The contract is 404.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 404, "NOT_FOUND")


def test_update_another_users_task_returns_404_not_403(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Private").expect(201).task
    resp = user.update_task(victim_task["id"], title="Hijacked")
    resp.implemented()
    assert resp.status != 403, (
        f"{user.impl}: updating another user's task returned 403; the contract is 404.\n"
        f"{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 404, "NOT_FOUND")

    unchanged = second_user.get_task(victim_task["id"])
    assert_success_envelope(unchanged, 200)
    assert unchanged.task["title"] == "Private", (
        f"{user.impl}: the cross-user update actually modified the task."
    )


def test_delete_another_users_task_returns_404_not_403(
    user: ApiClient, second_user: ApiClient
) -> None:
    victim_task = second_user.create_task("Private").expect(201).task
    resp = user.delete_task(victim_task["id"])
    resp.implemented()
    assert resp.status != 403, (
        f"{user.impl}: deleting another user's task returned 403; the contract is 404.\n"
        f"{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 404, "NOT_FOUND")

    survivor = second_user.get_task(victim_task["id"])
    assert_success_envelope(survivor, 200), "the cross-user delete actually deleted the task"


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "field,value",
    [
        ("title", "Retitled"),
        ("description", "New description"),
        ("description", None),
        ("priority", "high"),
        ("status", "in_progress"),
    ],
    ids=["title", "description", "clear_description", "priority", "status"],
)
def test_partial_update_touches_only_the_named_field(
    user: ApiClient, task: dict, field: str, value: object
) -> None:
    resp = user.update_task(task["id"], **{field: value})
    updated = assert_task_shape(resp, assert_success_envelope(resp, 200)["task"])

    assert updated[field] == value, f"{user.impl}: {field} was not updated"
    untouched = set(updated) - {field, "updatedAt", "completedAt"}
    for key in untouched:
        assert updated[key] == task[key], (
            f"{user.impl}: updating {field!r} also changed {key!r} "
            f"({task[key]!r} → {updated[key]!r}). PUT here is a partial update."
        )
    assert updated["updatedAt"] >= task["updatedAt"], (
        f"{user.impl}: updatedAt went backwards after an update"
    )


def test_update_to_completed_sets_completed_at(user: ApiClient, task: dict) -> None:
    assert task["completedAt"] is None
    resp = user.update_task(task["id"], status="completed")
    updated = assert_task_shape(resp, assert_success_envelope(resp, 200)["task"])

    assert updated["status"] == "completed"
    assert updated["completedAt"] is not None, (
        f"{user.impl}: setting status to 'completed' must populate completedAt "
        f"automatically; it is still null.\n{resp.exchange.render()}"
    )
    completed_at = parse_iso(updated["completedAt"])
    created_at = parse_iso(updated["createdAt"])
    assert completed_at >= created_at, "completedAt precedes createdAt"


def test_moving_away_from_completed_clears_completed_at(user: ApiClient, task: dict) -> None:
    user.update_task(task["id"], status="completed").expect(200)
    resp = user.update_task(task["id"], status="in_progress")
    updated = assert_success_envelope(resp, 200)["task"]
    assert updated["completedAt"] is None, (
        f"{user.impl}: completedAt must be cleared when a task leaves 'completed', "
        f"got {updated['completedAt']!r}. Otherwise a reopened task reports a "
        f"completion time.\n{resp.exchange.render()}"
    )


@pytest.mark.parametrize(
    "fields",
    [
        {"title": ""},
        {"title": "T" * 201},
        {"description": "d" * 5001},
        {"status": "done"},
        {"priority": "critical"},
        {"dueDate": past_iso(2)},
        {},
    ],
    ids=["empty_title", "long_title", "long_description", "bad_status", "bad_priority", "past_due", "empty_body"],
)
def test_update_validation(user: ApiClient, task: dict, fields: dict) -> None:
    assert_validation_error(user.update_task(task["id"], **fields))


def test_update_nonexistent_task_returns_404(user: ApiClient) -> None:
    assert_error_envelope(user.update_task(MISSING_TASK_ID, title="Ghost"), 404, "NOT_FOUND")


def test_update_can_clear_the_due_date(user: ApiClient) -> None:
    created = user.create_task("Has a due date", dueDate=future_iso(3)).expect(201).task
    resp = user.update_task(created["id"], dueDate=None)
    updated = assert_success_envelope(resp, 200)["task"]
    assert updated["dueDate"] is None


def test_update_requires_authentication(api: ApiClient) -> None:
    resp = api.put(f"/tasks/{MISSING_TASK_ID}", json_body={"title": "x"}, auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")


# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------


def test_delete_returns_a_message_envelope(user: ApiClient, task: dict) -> None:
    resp = user.delete_task(task["id"])
    data = assert_success_envelope(resp, 200)
    assert set(data) == {"message"}, f"delete data must be {{message}}, got {sorted(data)}"
    assert isinstance(data["message"], str) and data["message"]


def test_delete_is_soft_and_the_task_disappears(user: ApiClient, task: dict) -> None:
    """Soft delete: the row survives, the API does not admit it."""
    user.delete_task(task["id"]).expect(200)

    fetched = user.get_task(task["id"])
    assert_error_envelope(fetched, 404, "NOT_FOUND")

    listed = user.list_tasks(pageSize=100)
    assert_success_envelope(listed, 200)
    ids = {t["id"] for t in listed.data}
    assert task["id"] not in ids, (
        f"{user.impl}: a soft-deleted task is still listed. Every read path needs "
        f"`WHERE deleted_at IS NULL`, not just the single-task fetch.\n"
        f"{listed.exchange.render()}"
    )


def test_deleting_twice_returns_404_the_second_time(user: ApiClient, task: dict) -> None:
    user.delete_task(task["id"]).expect(200)
    assert_error_envelope(user.delete_task(task["id"]), 404, "NOT_FOUND")


def test_delete_nonexistent_task_returns_404(user: ApiClient) -> None:
    assert_error_envelope(user.delete_task(MISSING_TASK_ID), 404, "NOT_FOUND")


def test_updating_a_deleted_task_returns_404(user: ApiClient, task: dict) -> None:
    user.delete_task(task["id"]).expect(200)
    assert_error_envelope(user.update_task(task["id"], title="Zombie"), 404, "NOT_FOUND")


def test_delete_requires_authentication(api: ApiClient) -> None:
    resp = api.delete(f"/tasks/{MISSING_TASK_ID}", auth=False)
    assert_error_envelope(resp, 401, "UNAUTHORIZED")
