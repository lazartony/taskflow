"""Phase 3 — Database Depth.

These tests look at the database from both sides: through the API, and directly
with psycopg. That is the only way to assert things like "the row is still
there, the API just will not admit it" or "one list request issued one query,
not fifty-one".

The 1000-task corpus is inserted with SQL rather than 1000 POSTs — the subject
here is read performance, not write throughput, and a five-minute fixture is a
fixture nobody runs.
"""

from __future__ import annotations

import concurrent.futures as futures
import uuid

import pytest

from .assertions import assert_error_envelope, assert_success_envelope, assert_task_list
from .client import ApiClient
from .util import describe, percentile, sample

pytestmark = pytest.mark.phase3

#: NFR1 — p95 under 200 ms. The suite measures the *server* through a local
#: HTTP hop, so this includes a little client overhead; the target is generous
#: enough to absorb it and tight enough that a missing index fails it.
P95_BUDGET_MS = 200.0

SEED_SIZE = 1000
STATUSES = ("pending", "in_progress", "completed", "archived")
PRIORITIES = ("low", "medium", "high", "urgent")


@pytest.fixture
def heavy_user(user: ApiClient, db):
    """``user`` with 1000 tasks inserted straight into Postgres.

    Looked up by email rather than by decoding the API's ``usr_`` identifier —
    the five implementations are free to encode that prefix differently, and a
    test must not care.
    """
    row = db.rows("SELECT id FROM users WHERE email = %s AND deleted_at IS NULL", (user.email,))
    if not row:
        pytest.skip(
            f"{user.impl}: no users row for {user.email} — the API is not persisting "
            f"registrations to the database this suite is pointed at "
            f"(--postgres-dsn)."
        )
    user_uuid = row[0][0]

    values = [
        (
            user_uuid,
            f"Perf task {i:04d} {'documentation' if i % 5 == 0 else 'implementation'}",
            f"Body for perf task {i:04d}",
            STATUSES[i % 4],
            PRIORITIES[(i // 3) % 4],
        )
        for i in range(SEED_SIZE)
    ]
    with db.conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO tasks (user_id, title, description, status, priority, "
            "due_date, created_at, updated_at) VALUES (%s, %s, %s, %s::task_status, "
            "%s::task_priority, NOW() + INTERVAL '30 days', "
            "NOW() - (random() * INTERVAL '90 days'), NOW())",
            values,
        )
    db.conn.commit()

    yield user

    db.execute("DELETE FROM tasks WHERE user_id = %s", (user_uuid,))
    db.execute("DELETE FROM users WHERE id = %s", (user_uuid,))


# ---------------------------------------------------------------------------
# Read performance
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(300)
def test_task_list_p95_under_budget_with_1000_tasks(heavy_user: ApiClient) -> None:
    """NFR1: p95 of ``GET /tasks`` below 200 ms with a realistic row count.

    Sequential, one request at a time — this measures the query, not
    concurrency. A table scan over 1000 rows will still be fast; what fails
    here is a missing index combined with a sort, or an N+1.
    """

    def one_request() -> float:
        resp = heavy_user.list_tasks(page=1, pageSize=20)
        resp.expect(200)
        return resp.elapsed_ms

    latencies = sample(one_request, count=40, warmup=5)
    p95 = percentile(latencies, 95)
    assert p95 < P95_BUDGET_MS, (
        f"{heavy_user.impl}: GET /tasks p95 is {p95:.0f} ms with {SEED_SIZE} tasks, "
        f"over the {P95_BUDGET_MS:.0f} ms budget (NFR1).\n"
        f"  {describe(latencies)}\n"
        f"Check that idx_tasks_user_created_at is being used — `EXPLAIN (ANALYZE, "
        f"BUFFERS)` the list query and look for a Seq Scan or an external Sort."
    )


@pytest.mark.slow
@pytest.mark.timeout(300)
def test_filtered_and_sorted_queries_stay_within_budget(heavy_user: ApiClient) -> None:
    """The unindexed-sort trap: filtering is fast, sorting the result is not."""
    for params in (
        {"status": "pending"},
        {"priority": "high", "sortBy": "dueDate", "sortOrder": "asc"},
        {"search": "documentation"},
    ):

        def one_request(p=params) -> float:
            resp = heavy_user.list_tasks(pageSize=20, **p)
            resp.expect(200)
            return resp.elapsed_ms

        latencies = sample(one_request, count=20, warmup=3)
        p95 = percentile(latencies, 95)
        assert p95 < P95_BUDGET_MS * 1.5, (
            f"{heavy_user.impl}: GET /tasks {params} p95 is {p95:.0f} ms.\n"
            f"  {describe(latencies)}"
        )


@pytest.mark.slow
@pytest.mark.timeout(300)
def test_deep_pagination_does_not_degrade(heavy_user: ApiClient) -> None:
    """OFFSET 980 must not cost dramatically more than OFFSET 0.

    It always costs *something* — Postgres still walks the skipped rows — but an
    order-of-magnitude cliff means the sort is unindexed.
    """

    def timed(page: int) -> float:
        resp = heavy_user.list_tasks(page=page, pageSize=20)
        resp.expect(200)
        return resp.elapsed_ms

    shallow = sample(lambda: timed(1), count=15, warmup=3)
    deep = sample(lambda: timed(50), count=15, warmup=3)
    from .util import median

    shallow_median, deep_median = median(shallow), median(deep)
    assert deep_median < max(shallow_median * 8, 250.0), (
        f"{heavy_user.impl}: page 50 takes {deep_median:.0f} ms against "
        f"{shallow_median:.0f} ms for page 1 — an {deep_median / max(shallow_median, 1):.1f}× "
        f"cliff.\n  shallow: {describe(shallow)}\n  deep:    {describe(deep)}"
    )


# ---------------------------------------------------------------------------
# Query count — the N+1 detector
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_task_list_does_not_issue_a_query_per_row(heavy_user: ApiClient, db) -> None:
    """N+1: one query for the page, then one more per row returned.

    Measured as a ``pg_stat_statements`` delta. The bound is deliberately loose
    — other tests may be running in parallel against the same database — but an
    N+1 over a 50-row page moves the counter by ~500 for 10 requests, and this
    catches it by an order of magnitude.
    """
    try:
        before = db.scalar("SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements")
    except Exception as exc:
        pytest.skip(
            f"pg_stat_statements is not available ({exc}). docker-compose loads it via "
            f"shared_preload_libraries; the extension also needs CREATE EXTENSION."
        )

    requests_made = 10
    page_size = 50
    for _ in range(requests_made):
        heavy_user.list_tasks(page=1, pageSize=page_size).expect(200)

    after = db.scalar("SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements")
    delta = int(after) - int(before)
    budget = requests_made * 8  # page query + count query + auth lookup + slack

    assert delta <= budget, (
        f"{heavy_user.impl}: {requests_made} list requests over {page_size}-row pages "
        f"issued {delta} statements ({delta / requests_made:.1f} per request), over the "
        f"budget of {budget}. That is the shape of an N+1 — the list query returns the "
        f"rows and then something loads each row again.\n"
        f"Find it with: SELECT calls, query FROM pg_stat_statements ORDER BY calls DESC "
        f"LIMIT 10;"
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_query_count_is_independent_of_page_size(heavy_user: ApiClient, db) -> None:
    """The definitive N+1 signal: cost that scales with rows returned."""
    try:
        db.scalar("SELECT 1 FROM pg_stat_statements LIMIT 1")
    except Exception as exc:
        pytest.skip(f"pg_stat_statements is not available ({exc})")

    def queries_for(page_size: int, repeats: int = 5) -> int:
        before = int(db.scalar("SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements"))
        for _ in range(repeats):
            heavy_user.list_tasks(page=1, pageSize=page_size).expect(200)
        after = int(db.scalar("SELECT COALESCE(SUM(calls), 0) FROM pg_stat_statements"))
        return after - before

    small = queries_for(1)
    large = queries_for(100)
    assert large <= small + 40, (
        f"{heavy_user.impl}: 5 requests for 1 row cost {small} statements; 5 requests "
        f"for 100 rows cost {large}. Query count must not scale with rows returned."
    )


# ---------------------------------------------------------------------------
# Soft delete
# ---------------------------------------------------------------------------


def test_soft_deleted_tasks_are_invisible_on_every_read_path(user: ApiClient) -> None:
    """One missing ``WHERE deleted_at IS NULL`` is all it takes."""
    keep = user.create_task("Kept task", status="pending", priority="high").expect(201).task
    gone = user.create_task("Deleted task", status="pending", priority="high").expect(201).task
    user.delete_task(gone["id"]).expect(200)

    probes = {
        "unfiltered list": {},
        "status filter": {"status": "pending"},
        "priority filter": {"priority": "high"},
        "search": {"search": "Deleted task"},
        "sorted by dueDate": {"sortBy": "dueDate", "sortOrder": "asc"},
        "sorted by priority": {"sortBy": "priority"},
    }
    for label, params in probes.items():
        resp = user.list_tasks(pageSize=100, **params)
        ids = {t["id"] for t in assert_task_list(resp)}
        assert gone["id"] not in ids, (
            f"{user.impl}: the soft-deleted task is still visible via {label}. "
            f"Every read path needs the deleted_at predicate, not just the list one.\n"
            f"{resp.exchange.render()}"
        )
        if label != "search":
            assert keep["id"] in ids, f"{user.impl}: {label} lost a live task"

    assert_error_envelope(user.get_task(gone["id"]), 404, "NOT_FOUND")


def test_soft_delete_keeps_the_row_in_postgres(user: ApiClient, db) -> None:
    """"Soft" means the row survives with ``deleted_at`` set — not gone."""
    row = db.rows("SELECT id FROM users WHERE email = %s", (user.email,))
    if not row:
        pytest.skip(f"{user.impl}: cannot locate the test user in Postgres")
    user_uuid = row[0][0]

    task = user.create_task("Soon to be deleted").expect(201).task
    before = db.scalar(
        "SELECT COUNT(*) FROM tasks WHERE user_id = %s AND deleted_at IS NULL", (user_uuid,)
    )
    user.delete_task(task["id"]).expect(200)

    live = db.scalar(
        "SELECT COUNT(*) FROM tasks WHERE user_id = %s AND deleted_at IS NULL", (user_uuid,)
    )
    total = db.scalar("SELECT COUNT(*) FROM tasks WHERE user_id = %s", (user_uuid,))

    assert live == before - 1, f"{user.impl}: the delete did not mark the row deleted"
    assert total == before, (
        f"{user.impl}: DELETE /tasks/{{id}} physically removed the row "
        f"({before} → {total}). It must set deleted_at, so the data is recoverable and "
        f"the audit trail survives."
    )


def test_pagination_totals_exclude_soft_deleted_rows(user: ApiClient) -> None:
    created = [user.create_task(f"Countable {i}").expect(201).task for i in range(5)]
    for task in created[:2]:
        user.delete_task(task["id"]).expect(200)

    resp = user.list_tasks(pageSize=100)
    assert_task_list(resp)
    assert resp.pagination["totalItems"] == 3, (
        f"{user.impl}: totalItems is {resp.pagination['totalItems']} after deleting 2 of "
        f"5 tasks. The COUNT query needs the same deleted_at predicate as the SELECT — "
        f"otherwise the last page is empty and hasNext lies."
    )


# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_concurrent_updates_to_one_task_leave_it_consistent(
    user: ApiClient, new_client, task: dict
) -> None:
    """Last-write-wins is acceptable. A torn row is not.

    Ten writers set five different statuses at once. Afterwards the task must
    hold exactly one of them, with ``completedAt`` consistent with it — never a
    blend of two concurrent writes.
    """
    updates = [
        {"status": "in_progress", "priority": "high"},
        {"status": "completed", "priority": "urgent"},
        {"status": "pending", "priority": "low"},
        {"status": "archived", "priority": "medium"},
    ] * 3

    clients = [new_client() for _ in updates]
    for client in clients:
        client.access_token = user.access_token

    def apply(pair):
        client, payload = pair
        return client.update_task(task["id"], **payload)

    with futures.ThreadPoolExecutor(max_workers=len(updates)) as pool:
        results = list(pool.map(apply, zip(clients, updates)))

    server_errors = [r for r in results if r.status >= 500]
    assert not server_errors, (
        f"{user.impl}: {len(server_errors)} of {len(results)} concurrent updates returned "
        f"5xx. Concurrent writes to one row are ordinary traffic, not an error "
        f"condition.\n{server_errors[0].exchange.render()}"
    )
    accepted = [r for r in results if r.status == 200]
    assert accepted, f"{user.impl}: no concurrent update succeeded"

    final = user.get_task(task["id"])
    state = assert_success_envelope(final, 200)["task"]

    submitted = {(u["status"], u["priority"]) for u in updates}
    assert (state["status"], state["priority"]) in submitted, (
        f"{user.impl}: the task ended as status={state['status']!r} "
        f"priority={state['priority']!r}, which is not any single submitted update "
        f"{sorted(submitted)}. Two concurrent writes were interleaved within one row — "
        f"the update needs to be a single atomic statement, not read-modify-write."
    )
    if state["status"] == "completed":
        assert state["completedAt"] is not None, (
            f"{user.impl}: the winning write left status=completed with completedAt null"
        )
    else:
        assert state["completedAt"] is None, (
            f"{user.impl}: status is {state['status']!r} but completedAt is set — the "
            f"derived column is out of step with the concurrent winner"
        )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_concurrent_creates_all_persist(user: ApiClient, new_client) -> None:
    """Twenty simultaneous creates produce twenty distinct tasks."""
    count = 20
    clients = [new_client() for _ in range(count)]
    for client in clients:
        client.access_token = user.access_token

    nonce = uuid.uuid4().hex[:8]

    def create(pair):
        index, client = pair
        return client.create_task(f"Concurrent {nonce} {index:02d}")

    with futures.ThreadPoolExecutor(max_workers=count) as pool:
        results = list(pool.map(create, enumerate(clients)))

    created = [r for r in results if r.status == 201]
    assert len(created) == count, (
        f"{user.impl}: {len(created)}/{count} concurrent creates succeeded. "
        f"Statuses: {sorted({r.status for r in results})}"
    )
    ids = {r.task["id"] for r in created}
    assert len(ids) == count, (
        f"{user.impl}: {count} creates produced {len(ids)} distinct ids — id generation "
        f"is not collision-free under concurrency"
    )

    listed = user.list_tasks(search=nonce, pageSize=100)
    assert len(assert_task_list(listed)) == count, (
        f"{user.impl}: only {len(listed.data)} of {count} concurrently created tasks are "
        f"readable afterwards"
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_concurrent_delete_and_update_do_not_resurrect_a_task(
    user: ApiClient, new_client, task: dict
) -> None:
    """A delete racing an update must not leave the task alive and modified."""
    deleter, updater = new_client(), new_client()
    deleter.access_token = updater.access_token = user.access_token

    with futures.ThreadPoolExecutor(max_workers=2) as pool:
        delete_future = pool.submit(deleter.delete_task, task["id"])
        update_future = pool.submit(updater.update_task, task["id"], title="Racing update")
        delete_resp, update_resp = delete_future.result(), update_future.result()

    for resp in (delete_resp, update_resp):
        assert resp.status < 500, (
            f"{user.impl}: a delete/update race produced {resp.status}\n"
            f"{resp.exchange.render()}"
        )

    final = user.get_task(task["id"])
    if delete_resp.status == 200:
        assert final.status == 404, (
            f"{user.impl}: the delete succeeded but the task is still readable "
            f"({final.status}) — the concurrent update resurrected a deleted row.\n"
            f"{final.exchange.render()}"
        )
