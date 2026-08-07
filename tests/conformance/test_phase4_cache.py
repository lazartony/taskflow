"""Phase 4 — Caching & Rate Limiting.

Two properties matter for a cache and they pull against each other: it must make
reads faster, and it must be *invisible*. A cache that returns stale data after a
write is worse than no cache — the bug shows up in production, at low
reproducibility, days later.

Rate limiting is checked at both scopes (``/auth/*`` at 10/min, ``/tasks/*`` at
100/min) and, crucially, for *independence*: one bucket per scope, in shared
state, or two replicas silently double the limit.

The rate-limit tests carry ``@pytest.mark.xdist_group`` so ``-n auto`` runs them
in one worker rather than having four workers fight over the same bucket.
"""

from __future__ import annotations

import time
import uuid

import pytest

from .assertions import assert_error_envelope, assert_success_envelope, assert_task_list
from .client import ApiClient
from .dockerutil import container_env, docker_available
from .util import describe, future_iso, median

pytestmark = pytest.mark.phase4

AUTH_LIMIT = 10  # requests/minute — docker-compose RATE_LIMIT_AUTH_PER_MIN
TASKS_LIMIT = 100  # requests/minute — docker-compose RATE_LIMIT_TASKS_PER_MIN
CACHE_KEY_PREFIX = "taskflow:"

#: Below this, the uncached path is already so fast that a cache cannot be
#: measured through an HTTP hop without measuring noise instead.
MEASURABLE_FLOOR_MS = 3.0


def _strip_meta(body: dict) -> dict:
    return {k: v for k, v in body.items() if k != "meta"}


# ---------------------------------------------------------------------------
# Cache effectiveness
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_repeated_reads_are_faster_than_the_first(user: ApiClient) -> None:
    """A warm read beats a cold one — sampled, not measured once.

    Each iteration uses a *fresh* filter value so the first request is a
    guaranteed miss. Twenty pairs, compared on the median: a single timing
    measurement in a containerised stack is noise.
    """
    nonce = uuid.uuid4().hex[:8]
    for i in range(30):
        user.create_task(
            f"Cache corpus {nonce} {i:02d}",
            description="body text " * 20,
            dueDate=future_iso(60),
        ).expect(201)

    misses: list[float] = []
    hits: list[float] = []
    for i in range(20):
        # `dueDateFrom` moves by a millisecond each round: a cache key nobody has
        # seen before, over an identical result set. Without that, iteration 2
        # onwards would measure hit-vs-hit.
        cold_key = future_iso(1 + i / 86_400_000)
        params = {"pageSize": 20, "search": f"Cache corpus {nonce}", "dueDateFrom": cold_key}

        cold = user.list_tasks(**params)
        cold.expect(200)
        warm = user.list_tasks(**params)
        warm.expect(200)
        assert len(cold.data) == len(warm.data), (
            f"{user.impl}: the warm read returned a different number of tasks "
            f"({len(cold.data)} vs {len(warm.data)}) — not a like-for-like comparison"
        )
        misses.append(cold.elapsed_ms)
        hits.append(warm.elapsed_ms)

    cold_median, warm_median = median(misses), median(hits)
    if cold_median < MEASURABLE_FLOOR_MS:
        pytest.skip(
            f"{user.impl}: the uncached list already answers in {cold_median:.1f} ms; "
            f"a cache cannot be measured above the noise floor through HTTP. "
            f"Re-run against the 1000-task corpus if you want a real signal."
        )

    assert warm_median <= cold_median * 1.05, (
        f"{user.impl}: warm reads are not faster than cold ones "
        f"({warm_median:.1f} ms vs {cold_median:.1f} ms).\n"
        f"  cold: {describe(misses)}\n  warm: {describe(hits)}\n"
        f"Is CACHE_ENABLED true, and is the list endpoint actually consulting Valkey?"
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_cached_responses_are_byte_identical_apart_from_meta(user: ApiClient) -> None:
    """Transparency, part one: a hit and a miss return the same document."""
    for i in range(5):
        user.create_task(f"Identity check {i}").expect(201)

    bodies = []
    for _ in range(6):
        resp = user.list_tasks(pageSize=20)
        assert_task_list(resp)
        bodies.append(_strip_meta(resp.json()))

    first = bodies[0]
    for index, body in enumerate(bodies[1:], start=1):
        assert body == first, (
            f"{user.impl}: response {index} differs from the first for an identical "
            f"request. A cache must be invisible: same request, same answer.\n"
            f"  first: {first}\n  later: {body}"
        )


def test_a_write_invalidates_the_list_immediately(user: ApiClient) -> None:
    """Transparency, part two — the one that bites in production.

    create → list → create → list. The second list must contain the second task.
    A TTL-only cache passes every test except this one.
    """
    nonce = uuid.uuid4().hex[:8]
    first = user.create_task(f"Invalidation {nonce} one").expect(201).task

    before = user.list_tasks(search=nonce, pageSize=100)
    ids_before = {t["id"] for t in assert_task_list(before)}
    assert ids_before == {first["id"]}

    second = user.create_task(f"Invalidation {nonce} two").expect(201).task

    after = user.list_tasks(search=nonce, pageSize=100)
    ids_after = {t["id"] for t in assert_task_list(after)}
    assert second["id"] in ids_after, (
        f"{user.impl}: a task created after the list was cached is not visible on the "
        f"next identical request. The write path must invalidate (or version) the "
        f"list key — waiting for the TTL is not invalidation.\n"
        f"{after.exchange.render()}"
    )
    assert ids_after == {first["id"], second["id"]}


def test_an_update_invalidates_the_single_task_key(user: ApiClient, task: dict) -> None:
    user.get_task(task["id"]).expect(200)  # warm the key
    user.update_task(task["id"], title="Invalidated title").expect(200)

    fetched = user.get_task(task["id"])
    assert_success_envelope(fetched, 200)
    assert fetched.task["title"] == "Invalidated title", (
        f"{user.impl}: GET /tasks/{{id}} served the pre-update title "
        f"{fetched.task['title']!r} after a successful PUT."
    )


def test_a_delete_invalidates_both_keys(user: ApiClient, task: dict) -> None:
    user.get_task(task["id"]).expect(200)
    user.list_tasks(pageSize=100).expect(200)
    user.delete_task(task["id"]).expect(200)

    assert_error_envelope(user.get_task(task["id"]), 404, "NOT_FOUND")
    listed = user.list_tasks(pageSize=100)
    assert task["id"] not in {t["id"] for t in assert_task_list(listed)}, (
        f"{user.impl}: a deleted task is still served from the cached list"
    )


def test_one_users_cache_never_serves_another_user(
    user: ApiClient, second_user: ApiClient
) -> None:
    """The worst possible cache bug: a key that is not scoped to the owner."""
    mine = user.create_task("Strictly mine").expect(201).task
    user.list_tasks(pageSize=100).expect(200)

    theirs = second_user.list_tasks(pageSize=100)
    ids = {t["id"] for t in assert_task_list(theirs)}
    assert mine["id"] not in ids, (
        f"{second_user.impl}: another user's task came back from the cache. The cache "
        f"key must include the owner (taskflow:tasks:{{user_id}}:…).\n"
        f"{theirs.exchange.render()}"
    )


@pytest.mark.docker
def test_the_cache_is_actually_enabled(container_name: str, impl: str) -> None:
    """Guards against a green phase 4 that never touched Valkey."""
    if not docker_available():
        pytest.skip("the docker CLI is not available; cannot inspect container env")
    env = container_env(container_name)
    if env is None:
        pytest.skip(f"container {container_name} is not running; cannot inspect its env")
    value = env.get("CACHE_ENABLED", "").lower()
    assert value in ("true", "1", "yes"), (
        f"{impl}: CACHE_ENABLED is {value!r} in {container_name}. The phase 4 cache "
        f"tests can pass trivially with the cache off — turn it on before trusting them."
    )


# ---------------------------------------------------------------------------
# Valkey key hygiene
# ---------------------------------------------------------------------------


def test_cache_keys_use_the_taskflow_prefix(user: ApiClient, valkey) -> None:
    """One namespace, so ``DEL taskflow:*`` is a safe operation.

    Valkey is shared infrastructure. Unprefixed keys make a targeted flush
    impossible and turn a cache clear into a full ``FLUSHDB``.
    """
    for i in range(3):
        user.create_task(f"Key hygiene {i}").expect(201)
    user.list_tasks(pageSize=20).expect(200)
    user.me().expect(200)
    time.sleep(0.5)

    keys = [k for k in valkey.scan_iter(match="*", count=1000)]
    if not keys:
        pytest.skip(
            f"{user.impl}: Valkey holds no keys after cacheable reads — either "
            f"CACHE_ENABLED is false or nothing is being cached yet"
        )

    unprefixed = sorted(k for k in keys if not str(k).startswith(CACHE_KEY_PREFIX))
    assert not unprefixed, (
        f"{user.impl}: {len(unprefixed)} Valkey key(s) are outside the "
        f"{CACHE_KEY_PREFIX!r} namespace: {unprefixed[:10]}. Every key this project "
        f"writes must be prefixed so it can be flushed without touching anything else."
    )


def test_cache_keys_carry_a_ttl(user: ApiClient, valkey) -> None:
    """An unexpirable key is a memory leak with a long fuse."""
    user.list_tasks(pageSize=20).expect(200)
    time.sleep(0.5)

    cache_keys = [
        k for k in valkey.scan_iter(match=f"{CACHE_KEY_PREFIX}*", count=1000)
        if "ratelimit" not in str(k)
    ]
    if not cache_keys:
        pytest.skip(f"{user.impl}: no {CACHE_KEY_PREFIX}* cache keys present to inspect")

    immortal = [k for k in cache_keys[:50] if valkey.ttl(k) == -1]
    assert not immortal, (
        f"{user.impl}: {len(immortal)} cache key(s) have no TTL: {immortal[:5]}. "
        f"Even with perfect invalidation, the TTL is the backstop for the "
        f"invalidation you forgot."
    )


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------


def _rate_limit_headers(resp) -> dict[str, str]:
    return {
        name: value
        for name, value in resp.headers.items()
        if name.lower().startswith("x-ratelimit") or name.lower() == "retry-after"
    }


@pytest.mark.slow
@pytest.mark.timeout(180)
@pytest.mark.xdist_group("ratelimit")
def test_tasks_scope_returns_429_past_the_limit(user: ApiClient) -> None:
    """The 101st request in the window is refused, with the headers to explain it."""
    limited = None
    sent = 0
    for sent in range(1, TASKS_LIMIT + 40):
        resp = user.list_tasks(pageSize=1)
        resp.implemented()
        if resp.status == 429:
            limited = resp
            break
        assert resp.status == 200, (
            f"{user.impl}: request {sent} returned {resp.status} before the rate limit "
            f"engaged.\n{resp.exchange.render()}"
        )

    assert limited is not None, (
        f"{user.impl}: {sent} requests in one window and no 429. RATE_LIMIT_ENABLED is "
        f"true and RATE_LIMIT_TASKS_PER_MIN is {TASKS_LIMIT} in docker-compose — either "
        f"the limiter is off or it is counting something other than requests."
    )
    assert sent > TASKS_LIMIT * 0.5, (
        f"{user.impl}: the limiter engaged after only {sent} requests, well under the "
        f"configured {TASKS_LIMIT}/min. A limit that fires early is an outage."
    )

    error = assert_error_envelope(limited, 429, "RATE_LIMIT_EXCEEDED")
    details = error.get("details")
    assert isinstance(details, dict) and "retryAfter" in details, (
        f"{user.impl}: the 429 body carries no error.details.retryAfter. The client "
        f"needs to know how long to wait; guessing produces a retry storm.\n"
        f"{limited.exchange.render()}"
    )
    retry_after = details["retryAfter"]
    assert isinstance(retry_after, int) and not isinstance(retry_after, bool)
    assert 0 <= retry_after <= 86400


@pytest.mark.slow
@pytest.mark.timeout(180)
@pytest.mark.xdist_group("ratelimit")
def test_rate_limit_headers_are_present_and_coherent(user: ApiClient) -> None:
    first = user.list_tasks(pageSize=1)
    first.implemented()
    headers = {k.lower(): v for k, v in first.headers.items()}

    for name in ("x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset"):
        assert name in headers, (
            f"{user.impl}: a rate-limited endpoint must advertise {name} on *every* "
            f"response, not only on the 429. Present: {sorted(_rate_limit_headers(first))}\n"
            f"{first.exchange.render()}"
        )

    limit = int(headers["x-ratelimit-limit"])
    remaining = int(headers["x-ratelimit-remaining"])
    assert limit == TASKS_LIMIT, (
        f"{user.impl}: X-RateLimit-Limit is {limit}, docker-compose configures "
        f"RATE_LIMIT_TASKS_PER_MIN={TASKS_LIMIT}"
    )
    assert 0 <= remaining <= limit

    second = user.list_tasks(pageSize=1)
    second_remaining = int({k.lower(): v for k, v in second.headers.items()}["x-ratelimit-remaining"])
    assert second_remaining <= remaining, (
        f"{user.impl}: X-RateLimit-Remaining went up ({remaining} → {second_remaining}) "
        f"between two consecutive requests inside one window"
    )


@pytest.mark.slow
@pytest.mark.timeout(240)
@pytest.mark.xdist_group("ratelimit")
def test_429_response_carries_retry_after_header(user: ApiClient) -> None:
    limited = None
    for _ in range(TASKS_LIMIT + 40):
        resp = user.list_tasks(pageSize=1)
        if resp.status == 429:
            limited = resp
            break
    if limited is None:
        pytest.skip(f"{user.impl}: the tasks limiter did not engage; covered by its own test")

    retry_after = limited.headers.get("Retry-After")
    assert retry_after is not None, (
        f"{user.impl}: a 429 must carry the standard Retry-After header as well as "
        f"error.details.retryAfter. Headers: {_rate_limit_headers(limited)}"
    )
    assert retry_after.strip().isdigit(), (
        f"{user.impl}: Retry-After should be delta-seconds, got {retry_after!r}"
    )


@pytest.mark.slow
@pytest.mark.timeout(240)
@pytest.mark.xdist_group("ratelimit")
def test_auth_scope_limits_independently_of_tasks_scope(
    api: ApiClient, new_client
) -> None:
    """Two buckets, not one.

    A single global bucket means a burst of logins locks a user out of their own
    tasks. ``/auth/*`` is 10/min; ``/tasks/*`` is 100/min; exhausting one must
    leave the other usable.
    """
    victim = new_client()
    email = ApiClient.unique_email("scope")
    registration = victim.register(email=email)
    registration.implemented()
    if registration.status == 429:
        pytest.skip(
            f"{api.impl}: the /auth limiter was already exhausted before this test "
            f"could register its user — re-run with -m 'not slow' excluded and less "
            f"parallelism, or wait 60s"
        )
    registration.expect(201)

    limited = None
    attempts = 0
    for attempts in range(1, AUTH_LIMIT + 20):
        resp = victim.login(email, "DeliberatelyWrong123", remember=False)
        resp.implemented()
        if resp.status == 429:
            limited = resp
            break

    assert limited is not None, (
        f"{api.impl}: {attempts} login attempts without a 429. "
        f"RATE_LIMIT_AUTH_PER_MIN is {AUTH_LIMIT} — an auth endpoint with the same "
        f"limit as a read endpoint is a credential-stuffing budget."
    )
    assert attempts <= AUTH_LIMIT + 15, (
        f"{api.impl}: the auth limiter engaged only after {attempts} attempts, far "
        f"above the configured {AUTH_LIMIT}/min. Is /auth/* sharing the /tasks/* bucket?"
    )
    assert_error_envelope(limited, 429, "RATE_LIMIT_EXCEEDED")

    still_works = victim.list_tasks(pageSize=1)
    still_works.implemented()
    assert still_works.status != 429, (
        f"{api.impl}: exhausting the /auth/* limit also blocked /tasks/*. The two "
        f"scopes need separate buckets (infrastructure specification §3.6).\n"
        f"{still_works.exchange.render()}"
    )


@pytest.mark.slow
@pytest.mark.timeout(240)
@pytest.mark.xdist_group("ratelimit")
def test_rate_limit_is_per_user_not_global(user: ApiClient, second_user: ApiClient) -> None:
    """Shared state, per-user keys — one noisy user must not limit everyone."""
    limited = False
    for _ in range(TASKS_LIMIT + 20):
        resp = user.list_tasks(pageSize=1)
        if resp.status == 429:
            limited = True
            break
    if not limited:
        pytest.skip(f"{user.impl}: the limiter did not engage; covered by its own test")

    other = second_user.list_tasks(pageSize=1)
    other.implemented()
    assert other.status != 429, (
        f"{user.impl}: exhausting one user's quota rate-limited a different user. "
        f"The limiter key must include the subject.\n{other.exchange.render()}"
    )


def test_rate_limit_state_lives_in_valkey(user: ApiClient, valkey) -> None:
    """In-process counters work perfectly in dev and break at two replicas."""
    for _ in range(5):
        user.list_tasks(pageSize=1)
    time.sleep(0.3)

    keys = [str(k) for k in valkey.scan_iter(match=f"{CACHE_KEY_PREFIX}*", count=2000)]
    limiter_keys = [k for k in keys if "ratelimit" in k or "rate_limit" in k]
    assert limiter_keys, (
        f"{user.impl}: no rate-limit keys in Valkey after 5 requests "
        f"(saw {len(keys)} taskflow keys). An in-process counter gives you "
        f"limit × replicas, which is the same as no limit."
    )
