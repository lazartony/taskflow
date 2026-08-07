"""Appendix — the same events, over Kafka. Optional; see infrastructure spec §4.9.

Phase 6 runs on Valkey Streams because a single-service CRUD app does not need
a broker. If you want the real thing anyway — and it is worth doing once —
this module runs the envelope and ordering assertions against Kafka/Redpanda so
you can see for yourself that the concepts are the same and only the mechanics
moved: stream → topic, XADD → produce, consumer group → consumer group, PEL →
uncommitted offsets, XACK → offset commit.

Nothing here gates the phase. It is skipped unless you opt in::

    docker compose -f docker-compose.infra.yml --profile kafka up -d redpanda
    pytest -m appendix --kafka-brokers localhost:9092

Two things are deliberately *not* re-tested here, because they are properties of
the outbox rather than of the transport, and phase 6 already pins them down:
the same-transaction write, and writes surviving the transport being stopped.
Set ``EVENTS_BACKEND=kafka``, run ``-m phase6`` against the Kafka relay, and
those tests hold unchanged. That they need no edits is the point of the
appendix.
"""

from __future__ import annotations

import json
import time
import uuid
from typing import Any, Iterator

import pytest

from .assertions import TRACE_ID_RE, assert_success_envelope
from .client import ApiClient

pytestmark = pytest.mark.appendix

EVENT_WAIT_SECONDS = 15.0

#: Identical to the Streams list — the envelope is transport-independent (§4.4).
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


@pytest.fixture
def consumer(kafka_brokers: str, kafka_topic: str) -> Iterator[Any]:
    """A consumer parked at the end of the topic, so it only sees new events."""
    kafka = pytest.importorskip(
        "kafka", reason="kafka-python is required for the appendix: pip install kafka-python"
    )
    try:
        client = kafka.KafkaConsumer(
            bootstrap_servers=kafka_brokers.split(","),
            auto_offset_reset="latest",
            enable_auto_commit=False,
            group_id=f"conformance-{uuid.uuid4().hex[:8]}",
            consumer_timeout_ms=1000,
            value_deserializer=lambda raw: raw,
        )
    except Exception as exc:
        pytest.skip(f"kafka/redpanda not reachable at {kafka_brokers} ({exc})")

    try:
        if kafka_topic not in client.topics():
            client.close()
            pytest.skip(
                f"topic {kafka_topic!r} does not exist yet — bring up the kafka profile "
                f"(the redpanda-init service creates it), or "
                f"`rpk topic create {kafka_topic} -p 6 -r 1`"
            )
        client.subscribe([kafka_topic])
        # Force partition assignment and park at the tail before the test acts.
        deadline = time.monotonic() + 20
        while not client.assignment() and time.monotonic() < deadline:
            client.poll(timeout_ms=500)
        client.seek_to_end()
        yield client
    finally:
        try:
            client.close()
        except Exception:
            pass


def _drain(client: Any, seconds: float) -> list[tuple[bytes | None, dict]]:
    """Every decodable (key, event) published within ``seconds``."""
    records: list[tuple[bytes | None, dict]] = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for batch in client.poll(timeout_ms=500).values():
            for record in batch:
                try:
                    records.append((record.key, json.loads(record.value)))
                except (ValueError, TypeError):
                    continue
    return records


def _events_for(records: list[tuple[bytes | None, dict]], task_id: str) -> list[tuple[bytes | None, dict]]:
    matches = []
    for key, event in records:
        subject = event.get("subject") or {}
        data = event.get("data") or {}
        if subject.get("id") == task_id or data.get("id") == task_id:
            matches.append((key, event))
    return matches


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_the_envelope_is_identical_over_kafka(
    user: ApiClient, consumer, kafka_topic: str
) -> None:
    """Same §4.4 envelope, same required fields, same trace propagation.

    If this passes and the Streams version passes, you have demonstrated the
    thing worth demonstrating: the envelope is a contract, and the transport is
    an implementation detail underneath it.
    """
    resp = user.create_task(f"Appendix envelope {uuid.uuid4().hex[:8]}")
    task = assert_success_envelope(resp, 201)["task"]
    request_trace = resp.meta.get("traceId")

    matches = _events_for(_drain(consumer, EVENT_WAIT_SECONDS), task["id"])
    if not matches:
        pytest.fail(
            f"{user.impl}: no event for task {task['id']} appeared on {kafka_topic} within "
            f"{EVENT_WAIT_SECONDS:.0f}s. Is EVENTS_BACKEND=kafka and the relay pointed at "
            f"KAFKA_BROKERS?"
        )

    _key, event = matches[0]
    missing = [field for field in REQUIRED_EVENT_FIELDS if field not in event]
    assert not missing, (
        f"{user.impl}: the Kafka event envelope is missing {missing}.\n"
        f"Published: {json.dumps(event, indent=2, default=str)[:1200]}"
    )
    assert event.get("eventType") == "task.created", (
        f"{user.impl}: expected task.created, got {event.get('eventType')!r}"
    )
    assert TRACE_ID_RE.match(str(event["traceId"])), (
        f"{user.impl}: event traceId {event['traceId']!r} is not 32 lowercase hex"
    )
    assert event["traceId"] == request_trace, (
        f"{user.impl}: the event carries traceId {event['traceId']} but the request that "
        f"produced it was trace {request_trace} — the trace breaks at the async boundary. "
        f"On Kafka, also copy it into a `traceparent` record header so the OTel messaging "
        f"instrumentation picks it up without parsing the body."
    )
    assert str(event["eventId"]).startswith("evt_"), (
        f"{user.impl}: eventId should be a prefixed ULID, got {event['eventId']!r}"
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_events_are_keyed_by_user_so_one_user_stays_ordered(
    user: ApiClient, consumer
) -> None:
    """The one thing that genuinely differs from Streams.

    A Valkey stream is a single totally ordered log, so per-user ordering is
    free. Kafka orders only *within a partition*, and the record key picks the
    partition — so ordering is something you buy with a key, and a null key
    means every event goes to a random partition and per-user ordering is gone.
    That trade (ordering vs. horizontal parallelism) is the reason to look at
    Kafka at all; §4.8 is the honest version of what Streams gives up.
    """
    task = user.create_task(f"Appendix keying {uuid.uuid4().hex[:8]}").expect(201).task

    matches = _events_for(_drain(consumer, EVENT_WAIT_SECONDS), task["id"])
    if not matches:
        pytest.skip(f"{user.impl}: no event observed for {task['id']}; covered elsewhere")

    key, event = matches[0]
    assert key is not None, (
        f"{user.impl}: the event was published with a null key. Every event goes to a "
        f"random partition and per-user ordering is lost."
    )
    actor_id = (event.get("actor") or {}).get("id", "")
    assert actor_id and actor_id in key.decode("utf-8", "replace"), (
        f"{user.impl}: the partition key {key!r} does not contain the actor id "
        f"{actor_id!r}; the topic is keyed by user_id (infrastructure spec §4.9)"
    )


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_a_users_events_arrive_in_order_on_their_partition(
    user: ApiClient, consumer
) -> None:
    """Five creates by one user, one partition, five offsets in order."""
    created = [
        user.create_task(f"Appendix ordering {i} {uuid.uuid4().hex[:6]}").expect(201).task["id"]
        for i in range(5)
    ]

    records = _drain(consumer, EVENT_WAIT_SECONDS)
    positions: dict[str, int] = {}
    for index, (_key, event) in enumerate(records):
        if event.get("eventType") != "task.created":
            continue
        subject = event.get("subject") or {}
        data = event.get("data") or {}
        task_id = subject.get("id") or data.get("id")
        if task_id in created and task_id not in positions:
            positions[task_id] = index

    if len(positions) < len(created):
        pytest.skip(
            f"{user.impl}: only {len(positions)}/{len(created)} events arrived within "
            f"{EVENT_WAIT_SECONDS:.0f}s — ordering cannot be judged on a partial log"
        )

    observed = [positions[task_id] for task_id in created]
    assert observed == sorted(observed), (
        f"{user.impl}: five sequential creates by one user arrived out of order "
        f"({observed}). All of a user's events share a partition key, so the only way to "
        f"reorder them is to publish the outbox batch concurrently."
    )
