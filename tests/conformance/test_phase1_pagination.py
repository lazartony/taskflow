"""Phase 1 — Core API: pagination, filtering and sorting.

All of these run against ``seeded_user``: one account with the 45-task corpus
from ``conformance/seed.py``. Expected counts are *computed* from that corpus,
never hardcoded, so a failure message can say "9 tasks match, you returned 12"
and mean it.

45 is chosen so that ``pageSize=20`` gives a full page, a full page and a
partial one — the three cases where pagination arithmetic goes wrong.
"""

from __future__ import annotations

import pytest

from .assertions import (
    assert_error_envelope,
    assert_pagination,
    assert_success_envelope,
    assert_task_list,
)
from .seed import (
    PRIORITIES,
    STATUSES,
    TASK_COUNT,
    count,
    description_token,
    matching,
    title_token,
)
from .util import parse_iso

pytestmark = pytest.mark.phase1

PRIORITY_RANK = {"low": 0, "medium": 1, "high": 2, "urgent": 3}


def _ids(tasks: list[dict]) -> list[str]:
    return [t["id"] for t in tasks]


# ---------------------------------------------------------------------------
# Pagination metadata at the boundaries
# ---------------------------------------------------------------------------


def test_first_page_metadata_is_exact(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(page=1, pageSize=20)
    data = assert_task_list(resp)
    assert len(data) == 20, f"page 1 of 45 at pageSize 20 holds 20 tasks, got {len(data)}"
    assert_pagination(
        resp, page=1, pageSize=20, totalItems=45, totalPages=3, hasNext=True, hasPrev=False
    )


def test_middle_page_metadata_is_exact(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(page=2, pageSize=20)
    data = assert_task_list(resp)
    assert len(data) == 20
    assert_pagination(
        resp, page=2, pageSize=20, totalItems=45, totalPages=3, hasNext=True, hasPrev=True
    )


def test_last_page_is_partial_and_says_so(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(page=3, pageSize=20)
    data = assert_task_list(resp)
    assert len(data) == 5, (
        f"{seeded_user.impl}: the last page of 45 at pageSize 20 holds 5 tasks, got {len(data)}"
    )
    assert_pagination(
        resp, page=3, pageSize=20, totalItems=45, totalPages=3, hasNext=False, hasPrev=True
    )


def test_page_beyond_the_end_is_empty_but_still_well_formed(seeded_user) -> None:
    """Past the last page is an empty page, not a 404 and not an error."""
    resp = seeded_user.client.list_tasks(page=4, pageSize=20)
    data = assert_task_list(resp)
    assert data == [], f"{seeded_user.impl}: page 4 of 3 must be empty, got {len(data)} tasks"
    assert_pagination(
        resp, page=4, pageSize=20, totalItems=45, totalPages=3, hasNext=False, hasPrev=True
    )


def test_far_beyond_the_end_is_still_empty(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(page=1000, pageSize=20)
    data = assert_task_list(resp)
    assert data == []
    assert_pagination(resp, page=1000, totalItems=45, totalPages=3, hasNext=False, hasPrev=True)


def test_pages_partition_the_corpus_with_no_gaps_or_overlaps(seeded_user) -> None:
    """The classic off-by-one: page 2 repeating or skipping a row."""
    seen: list[str] = []
    for page in (1, 2, 3):
        resp = seeded_user.client.list_tasks(page=page, pageSize=20)
        seen.extend(_ids(assert_task_list(resp)))

    assert len(seen) == TASK_COUNT, f"3 pages returned {len(seen)} tasks, expected {TASK_COUNT}"
    duplicates = {i for i in seen if seen.count(i) > 1}
    assert not duplicates, (
        f"{seeded_user.impl}: {len(duplicates)} task(s) appeared on more than one page "
        f"({sorted(duplicates)[:5]}…). OFFSET arithmetic is off by one."
    )
    assert set(seen) == {t["id"] for t in seeded_user.created}, (
        f"{seeded_user.impl}: paging through the corpus did not return every task exactly once"
    )


@pytest.mark.parametrize("page_size", [1, 7, 20, 45, 100])
def test_page_size_is_honoured_exactly(seeded_user, page_size: int) -> None:
    resp = seeded_user.client.list_tasks(page=1, pageSize=page_size)
    data = assert_task_list(resp)
    assert len(data) == min(page_size, TASK_COUNT)
    assert_pagination(
        resp,
        page=1,
        pageSize=page_size,
        totalItems=TASK_COUNT,
        totalPages=-(-TASK_COUNT // page_size),
    )


def test_default_page_and_page_size(seeded_user) -> None:
    """Documented defaults: ``page=1``, ``pageSize=20``."""
    resp = seeded_user.client.list_tasks()
    data = assert_task_list(resp)
    assert_pagination(resp, page=1, pageSize=20)
    assert len(data) == 20


# ---------------------------------------------------------------------------
# Pagination parameter validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("page", [0, -1, -100], ids=["zero", "minus_one", "minus_hundred"])
def test_non_positive_page_is_rejected(seeded_user, page: int) -> None:
    resp = seeded_user.client.list_tasks(page=page)
    resp.implemented()
    assert resp.status == 400, (
        f"{seeded_user.impl}: page={page} returned {resp.status}. Pages are 1-indexed "
        f"with `minimum: 1`; anything below that is a 400, not a silent clamp — a "
        f"silent clamp hides the caller's bug.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 400, "VALIDATION_ERROR")


@pytest.mark.parametrize("page_size", [0, -1], ids=["zero", "negative"])
def test_non_positive_page_size_is_rejected(seeded_user, page_size: int) -> None:
    resp = seeded_user.client.list_tasks(pageSize=page_size)
    assert_error_envelope(resp, 400, "VALIDATION_ERROR")


@pytest.mark.parametrize("page_size", [101, 1000, 2**31 - 1])
def test_page_size_over_the_maximum_is_handled_identically(seeded_user, page_size: int) -> None:
    """``pageSize > 100`` may 400 or clamp — but all five must do the same thing.

    This test accepts either behaviour and pins the invariant that matters: no
    response ever contains more than 100 items. ``test_differential.py`` is what
    proves the five agree with *each other*.
    """
    resp = seeded_user.client.list_tasks(pageSize=page_size)
    resp.implemented()
    assert resp.status in (200, 400), (
        f"{seeded_user.impl}: pageSize={page_size} returned {resp.status}; expected a "
        f"400 or a clamped 200.\n{resp.exchange.render()}"
    )
    if resp.status == 400:
        assert_error_envelope(resp, 400, "VALIDATION_ERROR")
        return
    data = assert_task_list(resp)
    assert len(data) <= 100, (
        f"{seeded_user.impl}: pageSize={page_size} returned {len(data)} items. "
        f"The cap exists so one caller cannot ask for the whole table."
    )
    assert resp.pagination["pageSize"] <= 100, (
        f"{seeded_user.impl}: pagination.pageSize echoed {resp.pagination['pageSize']}, "
        f"above the documented maximum of 100"
    )


@pytest.mark.parametrize(
    "params",
    [{"page": "abc"}, {"pageSize": "many"}, {"page": "1.5"}, {"page": "1;DROP TABLE tasks"}],
    ids=["page_text", "page_size_text", "page_float", "page_injection"],
)
def test_non_integer_pagination_parameters_are_rejected(seeded_user, params: dict) -> None:
    resp = seeded_user.client.list_tasks(**params)
    resp.implemented()
    assert resp.status == 400, (
        f"{seeded_user.impl}: {params} returned {resp.status}; a non-integer page "
        f"parameter is a 400, never a 500 and never a silent default.\n"
        f"{resp.exchange.render()}"
    )


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("status", STATUSES)
def test_filter_by_status(seeded_user, status: str) -> None:
    expected = count(seeded_user.seed, status=status)
    resp = seeded_user.client.list_tasks(status=status, pageSize=100)
    data = assert_task_list(resp)
    assert_pagination(resp, totalItems=expected)
    assert len(data) == expected, (
        f"{seeded_user.impl}: status={status} matches {expected} of the {TASK_COUNT} "
        f"seeded tasks, got {len(data)}"
    )
    assert all(t["status"] == status for t in data), (
        f"{seeded_user.impl}: the status filter let through "
        f"{sorted({t['status'] for t in data})}"
    )


@pytest.mark.parametrize("priority", PRIORITIES)
def test_filter_by_priority(seeded_user, priority: str) -> None:
    expected = count(seeded_user.seed, priority=priority)
    resp = seeded_user.client.list_tasks(priority=priority, pageSize=100)
    data = assert_task_list(resp)
    assert_pagination(resp, totalItems=expected)
    assert len(data) == expected
    assert all(t["priority"] == priority for t in data)


def test_filter_by_search_matches_titles(seeded_user) -> None:
    token = title_token(seeded_user.nonce)
    expected = count(seeded_user.seed, search=token)
    resp = seeded_user.client.list_tasks(search=token, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == expected, (
        f"{seeded_user.impl}: search={token!r} matches {expected} seeded titles, got {len(data)}"
    )
    assert all(token in t["title"] for t in data)


def test_filter_by_search_matches_descriptions(seeded_user) -> None:
    """``search`` covers title *and* description — a title-only search is a bug."""
    token = description_token(seeded_user.nonce)
    expected = count(seeded_user.seed, search=token)
    resp = seeded_user.client.list_tasks(search=token, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == expected, (
        f"{seeded_user.impl}: search={token!r} appears in {expected} seeded descriptions, "
        f"got {len(data)}. The filter must match title OR description."
    )


def test_search_is_case_insensitive(seeded_user) -> None:
    token = title_token(seeded_user.nonce)
    lower = assert_task_list(seeded_user.client.list_tasks(search=token, pageSize=100))
    upper = assert_task_list(seeded_user.client.list_tasks(search=token.upper(), pageSize=100))
    assert _ids(lower) == _ids(upper), (
        f"{seeded_user.impl}: search is case-sensitive — {token!r} returned "
        f"{len(lower)} results and {token.upper()!r} returned {len(upper)}"
    )


def test_search_with_no_matches_returns_an_empty_page(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(search="nothingmatchesthisstring", pageSize=100)
    data = assert_task_list(resp)
    assert data == []
    assert_pagination(resp, totalItems=0, totalPages=0, hasNext=False, hasPrev=False)


def test_search_special_characters_are_not_interpreted(seeded_user) -> None:
    """``%`` and ``_`` are LIKE wildcards; unescaped they match everything."""
    resp = seeded_user.client.list_tasks(search="%", pageSize=100)
    resp.implemented()
    if resp.status == 400:
        return  # rejecting the input outright is also fine
    data = assert_task_list(resp)
    assert len(data) == 0, (
        f"{seeded_user.impl}: search='%' returned {len(data)} tasks. A literal percent "
        f"sign is being passed through to LIKE as a wildcard — the same hole that lets "
        f"'_' match any character."
    )


def test_filter_by_due_date_from(seeded_user) -> None:
    lower = seeded_user.seed[19]["dueDate"]
    expected = count(seeded_user.seed, dueDateFrom=lower)
    resp = seeded_user.client.list_tasks(dueDateFrom=lower, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == expected, (
        f"{seeded_user.impl}: dueDateFrom={lower} matches {expected} seeded tasks "
        f"(the bound is inclusive), got {len(data)}"
    )
    assert all(parse_iso(t["dueDate"]) >= parse_iso(lower) for t in data)


def test_filter_by_due_date_to(seeded_user) -> None:
    upper = seeded_user.seed[9]["dueDate"]
    expected = count(seeded_user.seed, dueDateTo=upper)
    resp = seeded_user.client.list_tasks(dueDateTo=upper, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == expected
    assert all(parse_iso(t["dueDate"]) <= parse_iso(upper) for t in data)


def test_filter_by_due_date_range(seeded_user) -> None:
    lower = seeded_user.seed[10]["dueDate"]
    upper = seeded_user.seed[29]["dueDate"]
    expected = count(seeded_user.seed, dueDateFrom=lower, dueDateTo=upper)
    resp = seeded_user.client.list_tasks(dueDateFrom=lower, dueDateTo=upper, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == expected == 20


def test_inverted_due_date_range_returns_nothing(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(
        dueDateFrom=seeded_user.seed[30]["dueDate"],
        dueDateTo=seeded_user.seed[5]["dueDate"],
        pageSize=100,
    )
    resp.implemented()
    if resp.status == 400:
        return  # rejecting an inverted range is defensible
    assert assert_task_list(resp) == []


@pytest.mark.parametrize(
    "params",
    [
        {"status": "done"},
        {"priority": "critical"},
        {"sortBy": "title"},
        {"sortOrder": "ascending"},
        {"dueDateFrom": "yesterday"},
    ],
    ids=["bad_status", "bad_priority", "bad_sort_by", "bad_sort_order", "bad_date"],
)
def test_invalid_filter_values_are_rejected(seeded_user, params: dict) -> None:
    resp = seeded_user.client.list_tasks(**params)
    resp.implemented()
    assert resp.status == 400, (
        f"{seeded_user.impl}: {params} returned {resp.status}. sortBy and sortOrder in "
        f"particular are allow-listed enums (SEC3.3) — an unknown value is a 400, never "
        f"an interpolated column name.\n{resp.exchange.render()}"
    )
    assert_error_envelope(resp, 400, "VALIDATION_ERROR")


# ---------------------------------------------------------------------------
# Filter combinations
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "filters",
    [
        {"status": "pending", "priority": "low"},
        {"status": "completed", "priority": "high"},
        {"status": "in_progress", "priority": "urgent"},
    ],
    ids=["pending_low", "completed_high", "in_progress_urgent"],
)
def test_status_and_priority_combine_as_and(seeded_user, filters: dict) -> None:
    expected = matching(seeded_user.seed, **filters)
    resp = seeded_user.client.list_tasks(pageSize=100, **filters)
    data = assert_task_list(resp)
    assert len(data) == len(expected), (
        f"{seeded_user.impl}: {filters} matches {len(expected)} seeded tasks, got "
        f"{len(data)}. Filters combine with AND, not OR."
    )
    for task in data:
        assert task["status"] == filters["status"]
        assert task["priority"] == filters["priority"]


def test_search_and_status_combine(seeded_user) -> None:
    filters = {"search": title_token(seeded_user.nonce), "status": "pending"}
    expected = matching(seeded_user.seed, **filters)
    resp = seeded_user.client.list_tasks(pageSize=100, **filters)
    assert len(assert_task_list(resp)) == len(expected)


def test_every_filter_at_once(seeded_user) -> None:
    filters = {
        "status": "pending",
        "priority": "low",
        "search": "Seed",
        "dueDateFrom": seeded_user.seed[0]["dueDate"],
        "dueDateTo": seeded_user.seed[-1]["dueDate"],
    }
    expected = matching(seeded_user.seed, **filters)
    resp = seeded_user.client.list_tasks(pageSize=100, **filters)
    data = assert_task_list(resp)
    assert len(data) == len(expected), (
        f"{seeded_user.impl}: all five filters together match {len(expected)} seeded "
        f"tasks, got {len(data)}"
    )


def test_filters_apply_before_pagination(seeded_user) -> None:
    """``totalItems`` counts matches, not rows in the table."""
    expected = count(seeded_user.seed, status="pending")
    resp = seeded_user.client.list_tasks(status="pending", page=1, pageSize=5)
    data = assert_task_list(resp)
    assert len(data) == 5
    assert_pagination(
        resp, page=1, pageSize=5, totalItems=expected, totalPages=-(-expected // 5)
    )


# ---------------------------------------------------------------------------
# Sorting
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sort_by", ["createdAt", "updatedAt", "dueDate"])
@pytest.mark.parametrize("sort_order", ["asc", "desc"])
def test_timestamp_sorts_are_actually_sorted(seeded_user, sort_by: str, sort_order: str) -> None:
    resp = seeded_user.client.list_tasks(sortBy=sort_by, sortOrder=sort_order, pageSize=100)
    data = assert_task_list(resp)
    assert len(data) == TASK_COUNT

    values = [parse_iso(t[sort_by]) for t in data]
    expected = sorted(values, reverse=(sort_order == "desc"))
    assert values == expected, (
        f"{seeded_user.impl}: sortBy={sort_by}&sortOrder={sort_order} is not ordered. "
        f"First divergence at index "
        f"{next(i for i, (a, b) in enumerate(zip(values, expected)) if a != b)}.\n"
        f"  got:      {[t[sort_by] for t in data][:5]}\n"
        f"  expected: {[v.isoformat() for v in expected][:5]}"
    )


@pytest.mark.parametrize("sort_order", ["asc", "desc"])
def test_priority_sort_groups_priorities_in_a_consistent_order(
    seeded_user, sort_order: str
) -> None:
    """``sortBy=priority`` must produce a stable, meaningful grouping.

    The contract does not fix *which* total order (semantic rank vs
    alphabetical), so this asserts the two properties that must hold either way:
    equal priorities are contiguous, and ``desc`` is the exact reverse ordering
    of ``asc``. ``test_differential.py`` then proves the five agree on which
    order it is.
    """
    resp = seeded_user.client.list_tasks(sortBy="priority", sortOrder=sort_order, pageSize=100)
    data = assert_task_list(resp)
    order = [t["priority"] for t in data]

    groups = [p for i, p in enumerate(order) if i == 0 or order[i - 1] != p]
    assert len(groups) == len(set(groups)), (
        f"{seeded_user.impl}: sortBy=priority returned interleaved priorities "
        f"({groups}). Equal keys must be contiguous."
    )


def test_priority_sort_directions_are_mirror_images(seeded_user) -> None:
    asc = assert_task_list(seeded_user.client.list_tasks(sortBy="priority", sortOrder="asc", pageSize=100))
    desc = assert_task_list(seeded_user.client.list_tasks(sortBy="priority", sortOrder="desc", pageSize=100))

    def groups(tasks: list[dict]) -> list[str]:
        order = [t["priority"] for t in tasks]
        return [p for i, p in enumerate(order) if i == 0 or order[i - 1] != p]

    asc_groups, desc_groups = groups(asc), groups(desc)
    assert asc_groups == list(reversed(desc_groups)), (
        f"{seeded_user.impl}: priority asc gives {asc_groups} but desc gives {desc_groups}; "
        f"one must be the reverse of the other."
    )


def test_default_sort_is_created_at_descending(seeded_user) -> None:
    resp = seeded_user.client.list_tasks(pageSize=100)
    data = assert_task_list(resp)
    values = [parse_iso(t["createdAt"]) for t in data]
    assert values == sorted(values, reverse=True), (
        f"{seeded_user.impl}: the documented default sort is createdAt desc — newest "
        f"first. The first three createdAt values were {[t['createdAt'] for t in data[:3]]}."
    )


def test_sort_is_stable_across_pages(seeded_user) -> None:
    """A sort with ties needs a tiebreaker or rows swap between pages."""
    first = _ids(assert_task_list(seeded_user.client.list_tasks(sortBy="priority", page=1, pageSize=20)))
    second = _ids(assert_task_list(seeded_user.client.list_tasks(sortBy="priority", page=2, pageSize=20)))
    third = _ids(assert_task_list(seeded_user.client.list_tasks(sortBy="priority", page=3, pageSize=20)))
    everything = first + second + third

    assert len(set(everything)) == TASK_COUNT, (
        f"{seeded_user.impl}: paging a priority-sorted list returned "
        f"{len(everything) - len(set(everything))} duplicate(s) and missed "
        f"{TASK_COUNT - len(set(everything))} task(s). A sort on a non-unique column "
        f"needs a deterministic tiebreaker (add `, id` to the ORDER BY)."
    )


def test_sorting_combines_with_filtering(seeded_user) -> None:
    expected = count(seeded_user.seed, status="pending")
    resp = seeded_user.client.list_tasks(
        status="pending", sortBy="dueDate", sortOrder="asc", pageSize=100
    )
    data = assert_task_list(resp)
    assert len(data) == expected
    due = [parse_iso(t["dueDate"]) for t in data]
    assert due == sorted(due)


def test_empty_list_for_a_user_with_no_tasks(user) -> None:
    resp = user.list_tasks()
    data = assert_success_envelope(resp, 200)
    assert data == [], f"{user.impl}: a brand-new account has no tasks, got {len(data)}"
    assert_pagination(
        resp, page=1, pageSize=20, totalItems=0, totalPages=0, hasNext=False, hasPrev=False
    )
