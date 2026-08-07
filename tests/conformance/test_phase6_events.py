"""Phase 6 — Event Streaming on Valkey Streams.

The transactional outbox is the point of this phase, so the tests are written
around its failure mode rather than its happy path: **the transport being down
must not fail the write**. If ``POST /tasks`` returns 500 because Valkey is
unreachable, the outbox is decorative — the whole pattern exists so the database
transaction and the event publication cannot disagree.

The transport here is Valkey Streams (`XADD`/`XGROUP`/`XREADGROUP`/`XACK`), not
Kafka. Every concept these tests assert on — durable log, consumer group,
pending entries, explicit acknowledgement, dead-letter path, at-least-once
delivery with idempotent consumers — is the same one Kafka teaches, minus a
gigabyte of broker. The optional Kafka parity run lives in
``test_appendix_kafka.py`` (``-m appendix``); see infrastructure spec §4.9.

Nothing in this file looks at *how* the relay publishes. It looks at what must
be true afterwards, which is the only thing five implementations can agree on.
"""

from __future__ import annotations

import json
import time
import uuid
from typing import Any, Iterable

import pytest

from .assertions import TRACE_ID_RE, assert_success_envelope
from .client import ApiClient
from .dockerutil import container_running, docker_available, start as docker_start, stop as docker_stop

pytestmark = pytest.mark.phase6

VALKEY_CONTAINER = "taskflow-valkey"

#: INF2 says "within seconds", and the relay polls every 200 ms
#: (OUTBOX_POLL_INTERVAL_MS in docker-compose), so 5 s is ~25 poll cycles.
EVENT_WAIT_SECONDS = 5.0
#: Consumers, the audit log and the PEL settle a little after publication.
SETTLE_SECONDS = 15.0

#: Infrastructure specification §4.4 — the event envelope.
REQUIRED_EVENT_FIELDS = (
    "eventId",
    "eventType",
    "eventVersion",
    "occurredAt",
    "producer",
    "traceId",
    "spanId",
    "subject",
    "actor",
    "data",
)

#: Field names an entry may use to carry the JSON envelope. ``payload`` is the
#: documented one (§4.4); the others are accepted so a reasonable-but-different
#: choice fails on *substance* rather than on a name.
ENVELOPE_FIELDS = ("payload", "event", "envelope", "data", "body", "value", "json")


# ---------------------------------------------------------------------------
# Reading the stream
# ---------------------------------------------------------------------------
#
# Entries are read with XRANGE from a recorded tip rather than XREADGROUP,
# deliberately: a conformance run must never consume from — or acknowledge in —
# the application's own consumer group, or the test would steal work from the
# service it is testing. XRANGE is a pure read and leaves the PEL untouched.


def _maybe_json(value: Any) -> Any:
    if isinstance(value, str) and value[:1] in ("{", "["):
        try:
            return json.loads(value)
        except ValueError:
            return value
    return value


def _envelope(fields: dict) -> dict | None:
    """The §4.4 envelope carried by one stream entry, or ``None``.

    Two shapes are accepted: the documented one (a single field holding the
    JSON envelope) and a flattened one (envelope members as stream fields).
    """
    for name in ENVELOPE_FIELDS:
        doc = _maybe_json(fields.get(name))
        if isinstance(doc, dict) and "eventType" in doc:
            return doc
    for value in fields.values():
        doc = _maybe_json(value)
        if isinstance(doc, dict) and "eventType" in doc:
            return doc
    if "eventType" in fields:
        return {key: _maybe_json(value) for key, value in fields.items()}
    return None


def _tip(client: Any, stream: str) -> str:
    """The last id currently on the stream — a marker to read forward from."""
    try:
        info = client.xinfo_stream(stream)
    except Exception:
        return "0-0"  # no such key yet; the relay will MKSTREAM it
    return str(info.get("last-generated-id", "0-0"))


def _entries_since(client: Any, stream: str, since: str, count: int = 1000) -> list[tuple[str, dict]]:
    """Every entry added after ``since``. Exclusive ranges need Valkey ≥ 7."""
    try:
        return client.xrange(stream, min=f"({since}", max="+", count=count)
    except Exception:
        return []


def _matches(entries: Iterable[tuple[str, dict]], task_id: str) -> list[tuple[str, dict]]:
    """(stream_id, envelope) pairs whose subject or data is ``task_id``."""
    found: list[tuple[str, dict]] = []
    for stream_id, fields in entries:
        envelope = _envelope(fields)
        if envelope is None:
            continue
        subject = envelope.get("subject") or {}
        data = envelope.get("data") or {}
        if not isinstance(subject, dict):
            subject = {}
        if not isinstance(data, dict):
            data = {}
        if subject.get("id") == task_id or data.get("id") == task_id:
            found.append((stream_id, envelope))
    return found


def _await_events(
    client: Any,
    stream: str,
    since: str,
    task_id: str,
    seconds: float = EVENT_WAIT_SECONDS,
    want: int = 1,
) -> list[tuple[str, dict]]:
    """Poll until ``want`` events for ``task_id`` show up, or time out."""
    deadline = time.monotonic() + seconds
    found: list[tuple[str, dict]] = []
    while time.monotonic() < deadline:
        found = _matches(_entries_since(client, stream, since), task_id)
        if len(found) >= want:
            return found
        time.sleep(0.25)
    return found


def _no_event(impl: str, stream: str, task_id: str, seconds: float) -> str:
    return (
        f"{impl}: no event for task {task_id} appeared on {stream!r} within "
        f"{seconds:.0f}s.\n"
        f"Check that OUTBOX_ENABLED is true, that the relay is running "
        f"(OUTBOX_POLL_INTERVAL_MS=200), and that it XADDs to this stream name — "
        f"the suite also scans for taskflow:*:events:task if ENV is not `dev`."
    )


def _raw_fields(client: Any, stream: str, stream_id: str) -> dict:
    entries = client.xrange(stream, min=stream_id, max=stream_id, count=1)
    return dict(entries[0][1]) if entries else {}


# ---------------------------------------------------------------------------
# Looking at the database
# ---------------------------------------------------------------------------


def _require_outbox(db) -> None:
    try:
        db.scalar("SELECT 1 FROM outbox LIMIT 1")
    except Exception as exc:
        db.conn.rollback()
        pytest.skip(f"no outbox table in this database ({exc}); migration 002 not applied?")


def _require_table(db, table: str) -> None:
    try:
        db.scalar(f"SELECT 1 FROM {table} LIMIT 1")
    except Exception as exc:
        db.conn.rollback()
        pytest.skip(f"no {table} table in this database ({exc}); migration 002 not applied?")


def _count_rows_mentioning(db, table: str, needle: str, column: str = "payload") -> int:
    """Rows whose JSONB payload mentions ``needle`` anywhere.

    Matching on the rendered JSON rather than a typed column on purpose: the
    outbox stores ``aggregate_id`` as a UUID while the API speaks ``tsk_…``,
    and how an implementation bridges the two is its own business.
    """
    db.conn.rollback()  # fresh snapshot: the relay commits from another session
    return int(
        db.scalar(
            f"SELECT COUNT(*) FROM {table} WHERE {column}::text LIKE %s", (f"%{needle}%",)
        )
    )


def _poll(fn, predicate, seconds: float, interval: float = 0.5):
    """Call ``fn`` until ``predicate`` holds. Returns the last value either way."""
    deadline = time.monotonic() + seconds
    value = fn()
    while time.monotonic() < deadline:
        if predicate(value):
            return value
        time.sleep(interval)
        value = fn()
    return value


# ---------------------------------------------------------------------------
# The outbox write — atomicity
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_creating_a_task_writes_its_outbox_row_in_the_same_transaction(
    user: ApiClient, db
) -> None:
    """No task without its event, no event without its task.

    Two things are checked, and the second is the interesting one. The count
    delta proves the row exists at all; the *timestamp* proves it was written
    beside the task rather than by some later job — an outbox row inserted a
    second after the commit is a dual write wearing a costume.
    """
    _require_outbox(db)
    db.conn.rollback()
    before = int(db.scalar("SELECT COUNT(*) FROM outbox"))

    marker = uuid.uuid4().hex[:12]
    resp = user.create_task(f"Atomicity {marker}")
    task = assert_success_envelope(resp, 201)["task"]

    db.conn.rollback()
    after = int(db.scalar("SELECT COUNT(*) FROM outbox"))
    # `>=` rather than `==`: under `-n auto` other workers are writing too. The
    # exact-count check below is scoped to this task's id and stays precise.
    assert after >= before + 1, (
        f"{user.impl}: a task create produced no outbox row at all. "
        f"The outbox insert belongs in the same transaction as the task insert — if it "
        f"is a separate call, a crash between the two loses the event silently."
    )

    rows = db.rows(
        "SELECT event_type, created_at, "
        "       EXTRACT(EPOCH FROM (created_at - %s::timestamptz)) "
        "  FROM outbox WHERE payload::text LIKE %s",
        (task["createdAt"], f"%{task['id']}%"),
    )
    assert len(rows) == 1, (
        f"{user.impl}: expected exactly one outbox row mentioning {task['id']}, found "
        f"{len(rows)}. Store the task id in the event payload (§4.4 `subject`/`data`) "
        f"so an event can be traced back to what produced it."
    )
    event_type, _created_at, skew_seconds = rows[0]
    assert event_type == "task.created", (
        f"{user.impl}: the outbox row for a new task has event_type {event_type!r}, "
        f"expected 'task.created' (§4.4)"
    )
    assert abs(float(skew_seconds)) <= 2.0, (
        f"{user.impl}: the outbox row was written {float(skew_seconds):+.1f}s away from the "
        f"task's own createdAt. Same transaction means same instant, give or take clock "
        f"resolution — this gap says the event is being written by a separate step, which "
        f"is the dual write the outbox exists to remove."
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_the_outbox_drains_to_zero(user: ApiClient, db) -> None:
    """A backlog that never clears is a relay that is not running."""
    _require_outbox(db)

    for i in range(5):
        user.create_task(f"Outbox drain {i}").expect(201)

    def backlog() -> int:
        db.conn.rollback()  # a fresh snapshot each poll
        return int(db.scalar("SELECT COUNT(*) FROM outbox WHERE published_at IS NULL"))

    remaining = _poll(backlog, lambda n: n == 0, seconds=60, interval=2)
    assert remaining == 0, (
        f"{user.impl}: {remaining} outbox row(s) are still unpublished after 60s. "
        f"The relay must poll, XADD, and mark rows published "
        f"(OUTBOX_POLL_INTERVAL_MS is 200 in docker-compose)."
    )


# ---------------------------------------------------------------------------
# Publication to the stream
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_the_event_reaches_the_stream_within_five_seconds(
    user: ApiClient, valkey, events_stream: str
) -> None:
    since = _tip(valkey, events_stream)
    resp = user.create_task(f"Event probe {uuid.uuid4().hex[:8]}")
    task = assert_success_envelope(resp, 201)["task"]

    found = _await_events(valkey, events_stream, since, task["id"])
    assert found, _no_event(user.impl, events_stream, task["id"], EVENT_WAIT_SECONDS)

    types = {envelope.get("eventType") for _, envelope in found}
    assert "task.created" in types, (
        f"{user.impl}: the event for a newly created task is `task.created`, got {types}"
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_the_event_envelope_carries_every_required_field(
    user: ApiClient, valkey, events_stream: str
) -> None:
    """Infrastructure specification §4.4 — including ``traceId``.

    Without ``traceId``/``spanId`` on the envelope the distributed trace stops
    dead at the producer, and the consumer's work shows up as an unrelated
    orphan trace. That is the single most common gap in event-driven systems,
    and a stream entry is no more forgiving about it than a Kafka record.
    """
    since = _tip(valkey, events_stream)
    resp = user.create_task(f"Envelope probe {uuid.uuid4().hex[:8]}")
    task = assert_success_envelope(resp, 201)["task"]
    request_trace = resp.meta.get("traceId")

    found = _await_events(valkey, events_stream, since, task["id"])
    if not found:
        pytest.fail(_no_event(user.impl, events_stream, task["id"], EVENT_WAIT_SECONDS))

    _, event = found[0]
    missing = [field for field in REQUIRED_EVENT_FIELDS if field not in event]
    assert not missing, (
        f"{user.impl}: the event envelope is missing {missing}.\n"
        f"Published: {json.dumps(event, indent=2, default=str)[:1200]}"
    )
    assert TRACE_ID_RE.match(str(event["traceId"])), (
        f"{user.impl}: event traceId {event['traceId']!r} is not 32 lowercase hex"
    )
    assert event["traceId"] == request_trace, (
        f"{user.impl}: the event carries traceId {event['traceId']} but the request that "
        f"produced it was trace {request_trace}. The producing span's context must "
        f"travel with the event or the trace breaks at the async boundary."
    )
    assert isinstance(event["subject"], dict) and event["subject"].get("type") == "task", (
        f"{user.impl}: subject must be {{type: 'task', id: …}}, got {event['subject']!r}"
    )
    assert isinstance(event["actor"], dict) and event["actor"].get("type") == "user", (
        f"{user.impl}: actor must be {{type: 'user', id: …}}, got {event['actor']!r}"
    )
    assert str(event["eventId"]).startswith("evt_"), (
        f"{user.impl}: eventId should be a prefixed ULID, got {event['eventId']!r}"
    )
    ulid = str(event["eventId"])[4:]
    assert len(ulid) == 26 and set(ulid) <= set("0123456789ABCDEFGHJKMNPQRSTVWXYZ"), (
        f"{user.impl}: eventId {event['eventId']!r} is not a Crockford-base32 ULID. "
        f"ULIDs sort by time, which is what makes an event log readable; UUIDv4 does not."
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_update_and_delete_publish_their_own_events(
    user: ApiClient, valkey, events_stream: str
) -> None:
    since = _tip(valkey, events_stream)
    task = user.create_task(f"Lifecycle {uuid.uuid4().hex[:8]}").expect(201).task
    user.update_task(task["id"], status="completed").expect(200)
    user.delete_task(task["id"]).expect(200)

    found = _await_events(valkey, events_stream, since, task["id"], seconds=SETTLE_SECONDS, want=3)
    types = {envelope.get("eventType") for _, envelope in found}
    assert "task.created" in types, _no_event(
        user.impl, events_stream, task["id"], SETTLE_SECONDS
    )
    assert types & {"task.updated", "task.status_changed"}, (
        f"{user.impl}: an update published {types}; expected task.updated or "
        f"task.status_changed"
    )
    assert "task.deleted" in types, (
        f"{user.impl}: the delete published no task.deleted event (saw {types})"
    )


@pytest.mark.slow
@pytest.mark.timeout(240)
def test_one_users_events_stay_in_order_on_the_stream(
    user: ApiClient, valkey, events_stream: str
) -> None:
    """Ordering, the Streams way.

    Kafka orders within a partition and you pick the partition with a key. A
    Valkey stream has no partitions, so a single stream *is* one totally
    ordered log: XADD ids are strictly increasing, and a consumer group hands
    entries out in id order. That is a stronger guarantee than Kafka gives —
    and, as §4.8 says, it is also the ceiling, because you cannot buy
    throughput by adding partitions.

    What is asserted here is the property the consumer depends on: for one
    user, events arrive in the order the writes happened.
    """
    since = _tip(valkey, events_stream)
    created = [
        user.create_task(f"Ordering {i} {uuid.uuid4().hex[:6]}").expect(201).task["id"]
        for i in range(5)
    ]

    deadline = time.monotonic() + SETTLE_SECONDS
    positions: dict[str, str] = {}
    while time.monotonic() < deadline:
        entries = _entries_since(valkey, events_stream, since)
        positions = {}
        for task_id in created:
            hits = [
                (sid, env)
                for sid, env in _matches(entries, task_id)
                if env.get("eventType") == "task.created"
            ]
            if hits:
                positions[task_id] = hits[0][0]
        if len(positions) == len(created):
            break
        time.sleep(0.5)

    if len(positions) < len(created):
        pytest.fail(
            f"{user.impl}: only {len(positions)}/{len(created)} task.created events reached "
            f"{events_stream!r} within {SETTLE_SECONDS:.0f}s — ordering cannot be judged "
            f"on a partial log. {_no_event(user.impl, events_stream, created[0], SETTLE_SECONDS)}"
        )

    observed = [positions[task_id] for task_id in created]
    ascending = all(_id_tuple(a) < _id_tuple(b) for a, b in zip(observed, observed[1:]))
    assert ascending, (
        f"{user.impl}: five sequential creates by one user landed on the stream out of "
        f"order.\n  created: {created}\n  stream ids: {observed}\n"
        f"The relay must publish in outbox id order — `ORDER BY id` in the claim query, "
        f"and one XADD at a time per user. Publishing the claimed batch concurrently is "
        f"the usual cause."
    )


def _id_tuple(stream_id: str) -> tuple[int, int]:
    """``1786128832215-0`` -> ``(1786128832215, 0)``; stream ids sort numerically."""
    ms, _, seq = str(stream_id).partition("-")
    try:
        return int(ms), int(seq or 0)
    except ValueError:  # pragma: no cover - defensive
        return (0, 0)


# ---------------------------------------------------------------------------
# Consumer groups, the PEL and acknowledgement
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_a_consumer_group_exists_and_its_pending_list_drains(
    user: ApiClient, valkey, events_stream: str, events_group: str
) -> None:
    """The PEL is the whole acknowledgement story in one number.

    XREADGROUP moves an entry into the group's pending-entries list; only XACK
    takes it out. A PEL that never shrinks means a consumer that reads and
    forgets to acknowledge — the Streams equivalent of never committing an
    offset, and it looks fine right up until the consumer restarts and replays
    everything it "processed".
    """
    try:
        groups = valkey.xinfo_groups(events_stream)
    except Exception as exc:
        pytest.skip(
            f"no consumer group on {events_stream!r} yet ({exc}). Create it with "
            f"`XGROUP CREATE {events_stream} {events_group} $ MKSTREAM` — the "
            f"valkey-streams-init service in docker-compose.infra.yml does this for you."
        )
    assert groups, (
        f"{user.impl}: {events_stream!r} exists but has no consumer group. Events nobody "
        f"consumes are decoration — build the notification/audit/analytics consumers "
        f"(§4.6) and give each its own group."
    )
    names = {str(group["name"]) for group in groups}
    assert events_group in names, (
        f"{user.impl}: expected a {events_group!r} consumer group on {events_stream!r}, "
        f"found {sorted(names)}. Pass --events-group if yours is named differently."
    )

    for i in range(3):
        user.create_task(f"PEL drain {i}").expect(201)

    def pending() -> int:
        info = {str(g["name"]): g for g in valkey.xinfo_groups(events_stream)}
        return int(info.get(events_group, {}).get("pending", 0))

    remaining = _poll(pending, lambda n: n == 0, seconds=SETTLE_SECONDS, interval=1.0)
    assert remaining == 0, (
        f"{user.impl}: {remaining} entr(ies) are still pending for group {events_group!r} "
        f"{SETTLE_SECONDS:.0f}s after the writes settled.\n"
        f"Every entry XREADGROUP hands you must end in an XACK (after the work is durable) "
        f"or on the DLQ. Check XPENDING {events_stream} {events_group} to see who is holding "
        f"them."
    )


@pytest.mark.timeout(120)
def test_unacknowledged_entries_are_redelivered_from_the_pending_list(valkey) -> None:
    """The redelivery mechanics a consumer must survive — on a private stream.

    This one needs no API: it pins down the Streams semantics the rest of the
    phase leans on, so that when a consumer of yours dies mid-processing you
    know exactly what happens next.

      1. XREADGROUP ``>`` delivers new entries and parks them in the PEL.
      2. Crash before XACK: ``>`` never shows them again — they are *this*
         consumer's problem now, not the group's.
      3. XAUTOCLAIM after ``min-idle-time`` moves them to another consumer.
         This is Streams' answer to a rebalance, and it is why a consumer that
         dies does not strand its in-flight work forever.
      4. XACK, and only then, removes them.

    Step 3 is the one people are surprised by: without an XAUTOCLAIM sweeper,
    a dead consumer's entries stay pending indefinitely. Nothing reclaims them
    automatically.
    """
    stream = f"taskflow:conformance:pel:{uuid.uuid4().hex[:12]}"
    group = "conformance"
    valkey.xgroup_create(stream, group, id="0", mkstream=True)
    try:
        first = valkey.xadd(stream, {"eventId": "evt_A", "n": "1"})
        second = valkey.xadd(stream, {"eventId": "evt_B", "n": "2"})

        delivered = valkey.xreadgroup(group, "consumer-1", {stream: ">"}, count=10)
        ids = [entry[0] for _, entries in delivered for entry in entries]
        assert ids == [first, second], (
            f"XREADGROUP '>' must deliver new entries in id order, got {ids}"
        )
        assert int(valkey.xpending(stream, group)["pending"]) == 2, (
            "reading with a group must park entries in the PEL until they are XACKed"
        )

        again = valkey.xreadgroup(group, "consumer-1", {stream: ">"}, count=10)
        assert not [e for _, entries in (again or []) for e in entries], (
            "'>' means 'entries never delivered to this group'. Re-reading it must not "
            "return the pending ones — that is what the PEL and XAUTOCLAIM are for."
        )

        # consumer-1 "dies". consumer-2 sweeps anything idle for >= 0 ms.
        _cursor, claimed, _deleted = valkey.xautoclaim(
            stream, group, "consumer-2", min_idle_time=0, start_id="0-0", count=10
        )
        assert [entry[0] for entry in claimed] == [first, second], (
            "XAUTOCLAIM must hand a dead consumer's pending entries to a live one; "
            f"got {claimed!r}"
        )

        valkey.xack(stream, group, first, second)
        assert int(valkey.xpending(stream, group)["pending"]) == 0, (
            "XACK is the only thing that empties the PEL"
        )
    finally:
        valkey.delete(stream)


# ---------------------------------------------------------------------------
# Idempotent consumers — exactly-once *processing*
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.destructive
@pytest.mark.timeout(240)
def test_replaying_an_event_produces_exactly_one_side_effect(
    user: ApiClient, db, valkey, events_stream: str
) -> None:
    """At-least-once delivery is a given; not double-applying it is on you.

    The relay can XADD and then crash before marking ``published_at``, so the
    same event goes out twice. That is unavoidable and correct. This test
    simulates it in the bluntest possible way — re-XADD the identical envelope,
    same ``eventId``, new stream id — and requires that the consumer notices.

    ``processed_events`` is how it notices: ``INSERT … ON CONFLICT DO NOTHING``
    in the same transaction as the side effect. Zero rows affected → already
    done → skip.
    """
    _require_table(db, "processed_events")
    _require_table(db, "audit_log")

    since = _tip(valkey, events_stream)
    task = user.create_task(f"Replay {uuid.uuid4().hex[:8]}").expect(201).task
    found = _await_events(valkey, events_stream, since, task["id"])
    if not found:
        pytest.skip(_no_event(user.impl, events_stream, task["id"], EVENT_WAIT_SECONDS))

    stream_id, envelope = found[0]
    audits = _poll(
        lambda: _count_rows_mentioning(db, "audit_log", task["id"]),
        lambda n: n >= 1,
        seconds=SETTLE_SECONDS,
    )
    if audits == 0:
        pytest.skip(
            f"{user.impl}: no audit_log row for {task['id']} — the audit consumer is not "
            f"running yet, so there is no side effect to double-apply. Covered by "
            f"test_the_audit_log_records_every_mutation."
        )
    assert audits == 1, (
        f"{user.impl}: {audits} audit_log rows for one create before any replay. "
        f"The consumer is already processing the event more than once."
    )

    # The relay's own id for this event, so processed_events can be checked
    # per-event rather than by a global count (which `-n auto` would race).
    db.conn.rollback()
    outbox_event_id = db.scalar(
        "SELECT event_id FROM outbox WHERE payload::text LIKE %s AND event_type = %s",
        (f"%{task['id']}%", "task.created"),
    )
    processed_query = (
        "SELECT consumer_group, processed_at FROM processed_events "
        " WHERE event_id = %s ORDER BY consumer_group"
    )
    before_rows = db.rows(processed_query, (outbox_event_id,))

    # The replay. Byte-identical fields, so the eventId is identical too.
    valkey.xadd(events_stream, _raw_fields(valkey, events_stream, stream_id))

    time.sleep(min(SETTLE_SECONDS, 10.0))
    audits_after = _count_rows_mentioning(db, "audit_log", task["id"])
    assert audits_after == 1, (
        f"{user.impl}: replaying one event left {audits_after} audit_log rows for "
        f"{task['id']} (expected 1). The consumer applied a duplicate.\n"
        f"Guard it: INSERT INTO processed_events (event_id, consumer_group) … "
        f"ON CONFLICT DO NOTHING, in the SAME transaction as the write. In a separate "
        f"transaction it protects nothing — a crash between the two replays the effect."
    )

    db.conn.rollback()
    after_rows = db.rows(processed_query, (outbox_event_id,))
    assert after_rows, (
        f"{user.impl}: nothing in processed_events is keyed by {outbox_event_id} — the "
        f"event id the outbox generated for {task['id']}. The consumer must record the "
        f"event's own id, not a fresh one, or the replay guard has nothing to collide "
        f"with. (A ULID is 128 bits, so `evt_<ULID>` on the wire and the UUID in "
        f"outbox.event_id are the same value in two encodings — keep them that way.)"
    )
    groups = [group for group, _ in after_rows]
    assert len(groups) == len(set(groups)), (
        f"{user.impl}: processed_events holds duplicate (event_id, consumer_group) rows "
        f"{groups} — exactly what the primary key exists to prevent."
    )
    assert after_rows == before_rows, (
        f"{user.impl}: the processed_events rows for this event changed when it was "
        f"redelivered:\n  before: {before_rows}\n  after:  {after_rows}\n"
        f"`ON CONFLICT DO NOTHING`, not `DO UPDATE`. A processed_at that moves means the "
        f"consumer re-ran the work and then rewrote the marker, so the guard recorded the "
        f"duplicate instead of stopping it."
    )


@pytest.mark.slow
@pytest.mark.timeout(240)
def test_the_audit_log_records_every_mutation(user: ApiClient, db) -> None:
    """Three mutations, three immutable rows — written by a consumer, not the API.

    The audit log is the reason the events have to be real. If ``audit_log``
    only fills in when the HTTP handler writes to it, you have an audit trail
    that agrees with the code path you already trusted; if a consumer fills it
    from the stream, it agrees with what was actually published.
    """
    _require_table(db, "audit_log")

    task = user.create_task(f"Audited {uuid.uuid4().hex[:8]}").expect(201).task
    user.update_task(task["id"], status="in_progress").expect(200)
    user.delete_task(task["id"]).expect(200)

    rows = _poll(
        lambda: _count_rows_mentioning(db, "audit_log", task["id"]),
        lambda n: n >= 3,
        seconds=SETTLE_SECONDS,
    )
    assert rows >= 3, (
        f"{user.impl}: three mutations produced {rows} audit_log row(s) for {task['id']} "
        f"within {SETTLE_SECONDS:.0f}s (expected create + update + delete).\n"
        f"The audit consumer reads the stream with its own group "
        f"(taskflow.audit), appends one row per event, then XACKs."
    )
    db.conn.rollback()
    distinct = int(
        db.scalar(
            "SELECT COUNT(DISTINCT event_id) FROM audit_log WHERE payload::text LIKE %s",
            (f"%{task['id']}%",),
        )
    )
    assert distinct == rows, (
        f"{user.impl}: {rows} audit_log rows carry only {distinct} distinct event_ids — "
        f"the same event was appended twice under different ids, which defeats the UNIQUE "
        f"constraint that makes the table replay-safe."
    )


# ---------------------------------------------------------------------------
# Dead letters
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.destructive
@pytest.mark.timeout(240)
def test_a_malformed_event_lands_on_the_dlq_without_blocking_the_stream(
    user: ApiClient, valkey, events_stream: str, events_dlq: str
) -> None:
    """A poison message must cost you one message, not the stream.

    Streams have no partitions, so one stuck entry does not stall a partition —
    it stalls *the consumer*, which is worse: every user's events queue behind
    it. The fix is the same as Kafka's. Try, fail, retry with backoff, then
    XADD the corpse to ``…:dlq`` with the reason, XACK the original, and keep
    moving. A DLQ is just another stream.
    """
    poison = uuid.uuid4().hex[:12]
    dlq_before = int(valkey.xlen(events_dlq))
    since = _tip(valkey, events_stream)

    valkey.xadd(
        events_stream,
        {"payload": '{"eventType": "task.created", "this is not json', "probe": poison},
    )

    # The stream must keep moving: a real event published after the poison one
    # has to arrive, and arrive promptly.
    task = user.create_task(f"After poison {poison}").expect(201).task
    found = _await_events(valkey, events_stream, since, task["id"], seconds=SETTLE_SECONDS)
    assert found, (
        f"{user.impl}: a malformed entry on {events_stream!r} blocked everything behind it — "
        f"the event for {task['id']} never arrived within {SETTLE_SECONDS:.0f}s.\n"
        f"Catch the decode failure, DLQ it, XACK it, continue. An unhandled exception in "
        f"the consumer loop turns one bad message into an outage for every user."
    )

    dlq_after = _poll(
        lambda: int(valkey.xlen(events_dlq)),
        lambda n: n > dlq_before,
        seconds=SETTLE_SECONDS,
    )
    assert dlq_after > dlq_before, (
        f"{user.impl}: the malformed entry never reached {events_dlq!r} "
        f"(length still {dlq_after}). Dropping a poison message silently is the one option "
        f"that is worse than retrying it forever: you lose the evidence. XADD it to the "
        f"DLQ with the error and the original entry id, then XACK the original."
    )


# ---------------------------------------------------------------------------
# Resilience — the reason the outbox exists
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.docker
@pytest.mark.destructive
@pytest.mark.timeout(300)
@pytest.mark.xdist_group("valkey")
def test_writes_still_succeed_with_valkey_stopped(user: ApiClient, db) -> None:
    """The key resilience property of the whole phase.

    With Valkey down, ``POST /tasks`` must still return 201 and the outbox row
    must accumulate for later delivery. An implementation that XADDs inline in
    the handler fails here with a 500 — which is exactly the coupling the
    pattern removes.

    Stopping Valkey also takes out the cache and the rate limiter, so this
    doubles as a check on INF1.7 (cache unavailability degrades to origin and
    never fails a request). If you see 500s, work out which of the three
    dependencies is the one that hard-fails.
    """
    if not docker_available():
        pytest.skip("the docker CLI is not available; cannot stop Valkey")
    if not container_running(VALKEY_CONTAINER):
        pytest.skip(f"{VALKEY_CONTAINER} is not running; nothing to stop")
    _require_outbox(db)

    assert docker_stop(VALKEY_CONTAINER, timeout_s=20), f"could not stop {VALKEY_CONTAINER}"
    try:
        time.sleep(3)
        db.conn.rollback()
        before = int(db.scalar("SELECT COUNT(*) FROM outbox WHERE published_at IS NULL"))

        created = []
        for i in range(3):
            resp = user.create_task(f"Transport down {i}")
            resp.implemented()
            assert resp.status == 201, (
                f"{user.impl}: POST /tasks returned {resp.status} with Valkey stopped. "
                f"The write path must not depend on the event transport being reachable — "
                f"that is the entire point of the transactional outbox.\n"
                f"{resp.exchange.render()}"
            )
            created.append(resp.task["id"])

        for task_id in created:
            assert user.get_task(task_id).status == 200, (
                f"{user.impl}: a task created while Valkey was down is not readable"
            )

        db.conn.rollback()
        after = int(db.scalar("SELECT COUNT(*) FROM outbox WHERE published_at IS NULL"))
        assert after >= before + len(created), (
            f"{user.impl}: the unpublished outbox backlog went {before} → {after} after "
            f"{len(created)} creates with Valkey down. The rows must accumulate so the "
            f"relay can deliver them when the transport returns — and a relay that marks "
            f"published_at without a successful XADD is losing events."
        )
    finally:
        docker_start(VALKEY_CONTAINER)
        time.sleep(5)


@pytest.mark.slow
@pytest.mark.docker
@pytest.mark.destructive
@pytest.mark.timeout(420)
@pytest.mark.xdist_group("valkey")
def test_the_backlog_drains_once_valkey_returns(
    user: ApiClient, db, valkey, events_stream: str
) -> None:
    """Recovery, not just survival: the relay catches up on its own, losing nothing."""
    if not docker_available():
        pytest.skip("the docker CLI is not available")
    if not container_running(VALKEY_CONTAINER):
        pytest.skip(f"{VALKEY_CONTAINER} is not running")
    _require_outbox(db)

    # Resolved before the outage; the client reconnects by itself afterwards.
    since = _tip(valkey, events_stream)
    created: list[str] = []
    assert docker_stop(VALKEY_CONTAINER, timeout_s=20)
    try:
        time.sleep(3)
        for i in range(3):
            created.append(user.create_task(f"Backlog {i}").expect(201).task["id"])
    finally:
        docker_start(VALKEY_CONTAINER)

    def backlog() -> int:
        db.conn.rollback()
        return int(db.scalar("SELECT COUNT(*) FROM outbox WHERE published_at IS NULL"))

    remaining = _poll(backlog, lambda n: n == 0, seconds=180, interval=5)
    assert remaining == 0, (
        f"{user.impl}: {remaining} outbox row(s) are still unpublished three minutes "
        f"after Valkey came back. The relay needs to retry, with backoff, indefinitely — "
        f"a backlog that only drains on restart is a data-loss window."
    )

    # Nothing lost: every task written during the outage has to be on the stream.
    # Valkey was restarted, not wiped, and the stream is durable, so the entries
    # published on recovery are still there to be read.
    entries = _entries_since(valkey, events_stream, since, count=10000)
    published = {task_id for task_id in created if _matches(entries, task_id)}
    assert published == set(created), (
        f"{user.impl}: the outbox reports itself drained, but "
        f"{sorted(set(created) - published)} never appeared on {events_stream!r}. "
        f"Marking published_at without a successful XADD turns an outage into silent "
        f"data loss — update the row only after the publish returns an id."
    )
