"""The 45-task fixture used by the pagination, filtering and sorting tests.

The seed is *data*, not magic numbers: every expected count in
``test_phase1_pagination.py`` is computed by filtering this list with plain
Python. If the seed changes, the expectations follow automatically — and a
learner reading a failure can see exactly which tasks should have matched.

Design constraints:

* 45 tasks, so page boundaries at pageSize 20 are 20 / 20 / 5 — a full page, a
  full page and a partial one.
* ``status`` cycles with period 4 and ``priority`` with period 12, so the two
  are *decorrelated*. Correlated fixtures make combined-filter tests pass by
  accident.
* Every ``dueDate`` is distinct and in the future, so range filters and
  ``sortBy=dueDate`` have an unambiguous answer.
* Search tokens are nonce-suffixed, so a search test can never match a task
  seeded by another test running in parallel.
"""

from __future__ import annotations

import datetime as dt
from typing import Any, Iterable

from .util import iso, now

TASK_COUNT = 45
STATUSES = ("pending", "in_progress", "completed", "archived")
PRIORITIES = ("low", "medium", "high", "urgent")


def title_token(nonce: str) -> str:
    return f"alphatoken{nonce}"


def description_token(nonce: str) -> str:
    return f"betatoken{nonce}"


def build_seed(nonce: str, base: dt.datetime | None = None) -> list[dict[str, Any]]:
    """Return the 45 ``CreateTaskRequest`` bodies, in creation order."""
    origin = (base or now()).replace(microsecond=0)
    seed: list[dict[str, Any]] = []
    for i in range(TASK_COUNT):
        title = f"Seed {i:02d} task"
        if i % 5 == 0:
            title = f"{title} {title_token(nonce)}"
        description = f"Description for seed {i:02d}"
        if i % 7 == 0:
            description = f"{description} {description_token(nonce)}"
        seed.append(
            {
                "title": title,
                "description": description,
                "status": STATUSES[i % 4],
                "priority": PRIORITIES[(i // 3) % 4],
                "dueDate": iso(origin + dt.timedelta(days=i + 1)),
            }
        )
    return seed


def matching(seed: Iterable[dict[str, Any]], **filters: Any) -> list[dict[str, Any]]:
    """Apply the documented filter semantics to the seed, in Python.

    Mirrors ``GET /tasks``: ``status`` and ``priority`` are exact matches,
    ``search`` is a case-insensitive substring of title *or* description, and
    the ``dueDate`` bounds are inclusive.
    """
    result = list(seed)
    if (status := filters.get("status")) is not None:
        result = [t for t in result if t["status"] == status]
    if (priority := filters.get("priority")) is not None:
        result = [t for t in result if t["priority"] == priority]
    if (search := filters.get("search")) is not None:
        needle = search.lower()
        result = [
            t
            for t in result
            if needle in t["title"].lower() or needle in (t["description"] or "").lower()
        ]
    if (lower := filters.get("dueDateFrom")) is not None:
        result = [t for t in result if t["dueDate"] >= lower]
    if (upper := filters.get("dueDateTo")) is not None:
        result = [t for t in result if t["dueDate"] <= upper]
    return result


def count(seed: Iterable[dict[str, Any]], **filters: Any) -> int:
    return len(matching(seed, **filters))
