"""End-to-end user journeys.

Where ``tests/conformance/`` checks endpoints one at a time, this file checks
*sequences*. Almost every interesting bug in an API lives between two calls
rather than inside one: a cache that is not invalidated, a soft delete that only
half applies, a token that survives logout, an ownership check that holds on
read but not on write.

Each journey is one test, so a failure names the step that broke.
"""

from __future__ import annotations

import uuid

import pytest

from conformance.assertions import (
    assert_error_envelope,
    assert_pagination,
    assert_success_envelope,
    assert_task_shape,
    assert_token_pair,
    assert_user_shape,
)
from conformance.client import VALID_PASSWORD, ApiClient
from conformance.util import future_iso, parse_iso

pytestmark = [pytest.mark.phase1, pytest.mark.e2e]


def test_register_create_filter_complete_delete(api: ApiClient) -> None:
    """The whole product in one test.

    register → create three tasks → filter them → complete one → check
    ``completedAt`` → delete it → confirm it is gone from every read path.
    """
    email = ApiClient.unique_email("journey")
    nonce = uuid.uuid4().hex[:8]

    # 1. Register.
    registration = api.register(email=email, display_name="Journey User")
    data = assert_success_envelope(registration, 201)
    assert_user_shape(registration, data["user"])
    assert_token_pair(registration, data["tokens"])

    # 2. A brand-new account owns nothing.
    empty = api.list_tasks()
    assert assert_success_envelope(empty, 200) == []
    assert_pagination(empty, page=1, totalItems=0, totalPages=0, hasNext=False, hasPrev=False)

    # 3. Create three tasks with different priorities.
    specs = [
        (f"Write the spec {nonce}", "high", future_iso(3)),
        (f"Review the spec {nonce}", "medium", future_iso(7)),
        (f"Ship the spec {nonce}", "urgent", future_iso(14)),
    ]
    created = []
    for title, priority, due in specs:
        resp = api.create_task(title, priority=priority, dueDate=due, description=f"part of {nonce}")
        task = assert_task_shape(resp, assert_success_envelope(resp, 201)["task"])
        assert task["status"] == "pending"
        created.append(task)

    # 4. They are all listed, newest first.
    listed = api.list_tasks(pageSize=100)
    assert_success_envelope(listed, 200)
    assert {t["id"] for t in listed.data} == {t["id"] for t in created}
    assert_pagination(listed, totalItems=3, totalPages=1, hasNext=False, hasPrev=False)

    # 5. Filter by priority, then by search, then by both.
    urgent = api.list_tasks(priority="urgent", pageSize=100)
    assert [t["id"] for t in assert_success_envelope(urgent, 200)] == [created[2]["id"]]

    searched = api.list_tasks(search=nonce, pageSize=100)
    assert len(assert_success_envelope(searched, 200)) == 3

    combined = api.list_tasks(search="Review", priority="medium", pageSize=100)
    assert [t["id"] for t in assert_success_envelope(combined, 200)] == [created[1]["id"]]

    # 6. Complete the middle one.
    target = created[1]
    assert target["completedAt"] is None
    completed = api.update_task(target["id"], status="completed")
    updated = assert_task_shape(completed, assert_success_envelope(completed, 200)["task"])
    assert updated["status"] == "completed"
    assert updated["completedAt"] is not None, (
        f"{api.impl}: completing a task must populate completedAt automatically"
    )
    assert parse_iso(updated["completedAt"]) >= parse_iso(updated["createdAt"])

    # 7. The status filter now sees it on the other side.
    still_pending = api.list_tasks(status="pending", pageSize=100)
    pending_ids = {t["id"] for t in assert_success_envelope(still_pending, 200)}
    assert target["id"] not in pending_ids
    assert len(pending_ids) == 2

    done = api.list_tasks(status="completed", pageSize=100)
    assert [t["id"] for t in assert_success_envelope(done, 200)] == [target["id"]]

    # 8. Delete it, and confirm it is gone everywhere.
    assert_success_envelope(api.delete_task(target["id"]), 200)
    assert_error_envelope(api.get_task(target["id"]), 404, "NOT_FOUND")

    after = api.list_tasks(pageSize=100)
    assert_success_envelope(after, 200)
    assert target["id"] not in {t["id"] for t in after.data}
    assert_pagination(after, totalItems=2, totalPages=1)

    completed_filter = api.list_tasks(status="completed", pageSize=100)
    assert assert_success_envelope(completed_filter, 200) == [], (
        f"{api.impl}: the deleted task still shows up under status=completed — the "
        f"filtered query is missing the deleted_at predicate"
    )

    search_after = api.list_tasks(search=nonce, pageSize=100)
    assert len(assert_success_envelope(search_after, 200)) == 2


def test_two_users_are_invisible_to_each_other_at_every_endpoint(
    user: ApiClient, second_user: ApiClient
) -> None:
    """Ownership is not one check in one handler; it is an invariant.

    Walks every endpoint that takes a task ID and confirms that user B is told
    the resource does not exist — never that it exists but is forbidden.
    """
    alice_tasks = [
        user.create_task(f"Alice {i}", priority="high").expect(201).task for i in range(3)
    ]
    bob_tasks = [
        second_user.create_task(f"Bob {i}", priority="low").expect(201).task for i in range(2)
    ]

    alice_list = user.list_tasks(pageSize=100)
    alice_ids = {t["id"] for t in assert_success_envelope(alice_list, 200)}
    assert alice_ids == {t["id"] for t in alice_tasks}
    assert_pagination(alice_list, totalItems=3)

    bob_list = second_user.list_tasks(pageSize=100)
    bob_ids = {t["id"] for t in assert_success_envelope(bob_list, 200)}
    assert bob_ids == {t["id"] for t in bob_tasks}
    assert_pagination(bob_list, totalItems=2)

    assert not alice_ids & bob_ids

    # Filters must not become a side channel.
    for params in ({"priority": "low"}, {"search": "Bob"}, {"status": "pending"}):
        resp = user.list_tasks(pageSize=100, **params)
        leaked = {t["id"] for t in assert_success_envelope(resp, 200)} & bob_ids
        assert not leaked, (
            f"{user.impl}: filtering with {params} leaked {len(leaked)} of Bob's tasks "
            f"to Alice.\n{resp.exchange.render()}"
        )

    victim = bob_tasks[0]["id"]
    for label, resp in (
        ("read", user.get_task(victim)),
        ("update", user.update_task(victim, title="Hijacked")),
        ("delete", user.delete_task(victim)),
        ("list attachments", user.list_attachments(victim)),
    ):
        resp.implemented()
        assert resp.status != 403, (
            f"{user.impl}: {label} on another user's task returned 403, which confirms "
            f"the resource exists. The contract is 404 everywhere.\n"
            f"{resp.exchange.render()}"
        )
        assert resp.status == 404, (
            f"{user.impl}: {label} on another user's task returned {resp.status}; "
            f"expected 404.\n{resp.exchange.render()}"
        )

    # Nothing Alice tried actually changed anything.
    survivor = second_user.get_task(victim)
    assert_success_envelope(survivor, 200)
    assert survivor.task["title"] == bob_tasks[0]["title"]

    intact = second_user.list_tasks(pageSize=100)
    assert len(assert_success_envelope(intact, 200)) == 2

    # Profiles are private too.
    alice_me = user.me()
    bob_me = second_user.me()
    assert assert_success_envelope(alice_me, 200)["user"]["email"] == user.email
    assert assert_success_envelope(bob_me, 200)["user"]["email"] == second_user.email
    assert alice_me.user["id"] != bob_me.user["id"]


def test_token_lifecycle_from_login_to_logout(api: ApiClient, new_client) -> None:
    """login → use → refresh → use the new pair → logout → the old pair is dead."""
    email = ApiClient.unique_email("lifecycle")
    api.register(email=email, display_name="Lifecycle User").expect(201)

    # 1. Log in on a second, independent client — a new session.
    session = new_client()
    login = session.login(email, VALID_PASSWORD)
    assert_success_envelope(login, 200)
    first_access = session.access_token
    first_refresh = session.refresh_token

    # 2. The access token works.
    assert_success_envelope(session.me(), 200)
    task = session.create_task("Made with the first token").expect(201).task

    # 3. Refresh — both tokens must change.
    refreshed = session.refresh(first_refresh)
    tokens = assert_token_pair(refreshed, assert_success_envelope(refreshed, 200)["tokens"])
    assert tokens["accessToken"] != first_access
    assert tokens["refreshToken"] != first_refresh

    # 4. The new access token works and sees the same data.
    me = session.get("/auth/me", token=tokens["accessToken"])
    assert assert_success_envelope(me, 200)["user"]["email"] == email
    fetched = session.get_task(task["id"], token=tokens["accessToken"])
    assert assert_success_envelope(fetched, 200)["task"]["id"] == task["id"]

    # 5. The rotated refresh token is dead.
    replay = session.refresh(first_refresh, remember=False)
    replay.implemented()
    assert replay.status == 401, (
        f"{api.impl}: the rotated refresh token still works ({replay.status}). "
        f"Rotation without invalidating the old token buys nothing.\n"
        f"{replay.exchange.render()}"
    )

    # 6. Log out, and the current refresh token stops working.
    current_refresh = tokens["refreshToken"]
    logout = session.logout(current_refresh)
    assert set(assert_success_envelope(logout, 200)) == {"message"}

    after_logout = session.refresh(current_refresh, remember=False)
    after_logout.implemented()
    assert after_logout.status == 401, (
        f"{api.impl}: the refresh token survived logout ({after_logout.status}).\n"
        f"{after_logout.exchange.render()}"
    )

    # 7. A fresh login still works — logout ends a session, not an account.
    relogin = new_client()
    assert_success_envelope(relogin.login(email, VALID_PASSWORD), 200)
    assert_success_envelope(relogin.get_task(task["id"]), 200)


def test_a_days_work_survives_pagination_and_reordering(user: ApiClient) -> None:
    """A realistic backlog: create 25, work through them, page and sort throughout."""
    nonce = uuid.uuid4().hex[:8]
    for index in range(25):
        user.create_task(
            f"Backlog {nonce} {index:02d}",
            priority=("low", "medium", "high", "urgent")[index % 4],
            dueDate=future_iso(index + 1),
        ).expect(201)

    page_one = user.list_tasks(page=1, pageSize=10, sortBy="dueDate", sortOrder="asc")
    assert len(assert_success_envelope(page_one, 200)) == 10
    assert_pagination(page_one, page=1, totalItems=25, totalPages=3, hasNext=True, hasPrev=False)

    # Complete the five most urgent things.
    urgent = user.list_tasks(priority="urgent", pageSize=100)
    urgent_tasks = assert_success_envelope(urgent, 200)
    for task in urgent_tasks[:5]:
        user.update_task(task["id"], status="completed").expect(200)

    remaining = user.list_tasks(status="pending", pageSize=100)
    pending = assert_success_envelope(remaining, 200)
    assert len(pending) == 25 - min(5, len(urgent_tasks))

    # Archive everything completed, then confirm the counts still add up.
    completed = user.list_tasks(status="completed", pageSize=100)
    for task in assert_success_envelope(completed, 200):
        assert task["completedAt"] is not None
        user.update_task(task["id"], status="archived").expect(200)

    archived = user.list_tasks(status="archived", pageSize=100)
    archived_tasks = assert_success_envelope(archived, 200)
    assert len(archived_tasks) == min(5, len(urgent_tasks))
    for task in archived_tasks:
        assert task["completedAt"] is None, (
            f"{user.impl}: a task moved from completed to archived kept its "
            f"completedAt. The field tracks the current status, not history."
        )

    total = user.list_tasks(pageSize=100)
    assert len(assert_success_envelope(total, 200)) == 25
    assert_pagination(total, totalItems=25)


def test_a_task_edited_repeatedly_stays_consistent(user: ApiClient) -> None:
    """Six sequential edits; every read must reflect the last write."""
    task = user.create_task("Iteration 0", priority="low").expect(201).task
    previous_updated = task["updatedAt"]

    edits = [
        {"title": "Iteration 1"},
        {"description": "Now with a description"},
        {"priority": "high"},
        {"status": "in_progress"},
        {"dueDate": future_iso(5)},
        {"status": "completed"},
    ]
    state = dict(task)
    for index, edit in enumerate(edits, start=1):
        resp = user.update_task(task["id"], **edit)
        updated = assert_task_shape(resp, assert_success_envelope(resp, 200)["task"])
        state.update(edit)

        fetched = user.get_task(task["id"])
        read_back = assert_success_envelope(fetched, 200)["task"]
        assert read_back == updated, (
            f"{user.impl}: after edit {index} the PUT response and the following GET "
            f"disagree — a stale cache entry.\n  PUT: {updated}\n  GET: {read_back}"
        )
        for field, value in edit.items():
            assert read_back[field] == value, (
                f"{user.impl}: edit {index} set {field}={value!r} but the task reads "
                f"{read_back[field]!r}"
            )
        assert read_back["updatedAt"] >= previous_updated
        previous_updated = read_back["updatedAt"]

    final = user.get_task(task["id"])
    task_state = assert_success_envelope(final, 200)["task"]
    assert task_state["status"] == "completed"
    assert task_state["completedAt"] is not None
    assert task_state["title"] == "Iteration 1"
    assert task_state["priority"] == "high"
