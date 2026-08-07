"""Phase 2 — Observability.

Two halves:

* **In-band** — the trace context that every response carries: ``meta.traceId``,
  the ``traceresponse`` header, and W3C propagation of an inbound
  ``traceparent``.
* **Out-of-band** — the RED metrics, checked one hop downstream in Prometheus
  because a test process cannot scrape OTLP.

The bucket-boundary test is the one that makes the whole cross-language
benchmark valid. If Go measures with different histogram buckets than Rust, a
p95 comparison between them is meaningless, and nothing else in the project will
tell you.
"""

from __future__ import annotations

import re
import uuid

import pytest

from .assertions import SPAN_ID_RE, TRACEPARENT_RE, assert_trace_id
from .client import ApiClient
from .phases import IMPL_SERVICE_NAMES
from .prom import Prometheus, PrometheusError

pytestmark = pytest.mark.phase2

DURATION_COUNT = "http_server_request_duration_seconds_count"
DURATION_BUCKET = "http_server_request_duration_seconds_bucket"

#: Normative bucket boundaries — observability specification §5.2. All five
#: implementations must use exactly these, or latency comparison is fiction.
REQUIRED_BUCKETS: tuple[str, ...] = (
    "0.005", "0.01", "0.025", "0.05", "0.075", "0.1",
    "0.25", "0.5", "0.75", "1", "2.5", "5", "7.5", "10", "+Inf",
)

#: Anything matching these in a *label value* is unbounded cardinality.
UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
ID_PREFIX_RE = re.compile(r"\b(usr|tsk|att|upl|req)_[a-zA-Z0-9]{6,}")

# Label names that legitimately carry free-form values and are not part of the
# metric's key space.
CARDINALITY_EXEMPT_LABELS = {"__name__", "instance", "job", "service_instance_id"}


@pytest.fixture
def prometheus(prometheus_url: str) -> Prometheus:
    return Prometheus(prometheus_url)


def _normalise_le(value: str) -> str:
    """Prometheus renders ``le`` as ``1`` or ``1.0`` depending on the exporter."""
    if value in ("+Inf", "Inf", "inf"):
        return "+Inf"
    try:
        number = float(value)
    except ValueError:
        return value
    text = f"{number:.10f}".rstrip("0").rstrip(".")
    return text or "0"


REQUIRED_LE = {_normalise_le(v) for v in REQUIRED_BUCKETS}


# ---------------------------------------------------------------------------
# In-band trace context
# ---------------------------------------------------------------------------


def test_every_response_carries_a_trace_id(api: ApiClient) -> None:
    assert_trace_id(api.get("/health/live", auth=False))


def test_trace_id_is_present_on_errors_too(api: ApiClient) -> None:
    """The response you most need to trace is the one that failed."""
    resp = api.get("/tasks", auth=False)
    if resp.status < 400:
        pytest.skip("GET /tasks without a token did not produce an error to inspect")
    assert_trace_id(resp)


def test_trace_id_differs_between_requests(api: ApiClient) -> None:
    ids = {assert_trace_id(api.get("/health/live", auth=False)) for _ in range(5)}
    assert len(ids) == 5, (
        f"{api.impl}: meta.traceId repeated across requests ({sorted(ids)}). Each "
        f"request is its own trace unless the caller supplies a traceparent."
    )


def test_traceresponse_header_is_present_and_well_formed(api: ApiClient) -> None:
    """W3C Trace Context Level 2 — the server tells the client which trace it used."""
    resp = api.get("/health/live", auth=False)
    resp.implemented()
    header = resp.headers.get("traceresponse") or resp.headers.get("Traceresponse")
    assert header is not None, (
        f"{api.impl}: no `traceresponse` response header. Without it a client cannot "
        f"correlate its call with the server's trace.\nHeaders: {dict(resp.headers)}"
    )
    assert TRACEPARENT_RE.match(header.strip()), (
        f"{api.impl}: traceresponse must be 00-<32 hex>-<16 hex>-<2 hex>, got {header!r}"
    )
    trace_id = assert_trace_id(resp)
    assert header.split("-")[1] == trace_id, (
        f"{api.impl}: the traceresponse header names trace {header.split('-')[1]} but "
        f"meta.traceId says {trace_id}. They are the same trace."
    )


def test_inbound_traceparent_is_propagated(api: ApiClient) -> None:
    """The distributed part of distributed tracing.

    A service that mints a fresh trace ID instead of continuing the caller's
    breaks every trace at its own front door — and the failure is invisible
    until you go looking for a trace that should span three services.
    """
    trace_id = uuid.uuid4().hex  # 32 lowercase hex, a valid W3C trace ID
    span_id = uuid.uuid4().hex[:16]
    resp = api.get(
        "/health/live",
        auth=False,
        headers={"traceparent": f"00-{trace_id}-{span_id}-01"},
    )
    returned = assert_trace_id(resp)
    assert returned == trace_id, (
        f"{api.impl}: sent traceparent with trace ID {trace_id}, response reported "
        f"{returned}. The W3C propagator is not extracting the inbound context "
        f"(OTEL_PROPAGATORS=tracecontext,baggage).\n{resp.exchange.render()}"
    )


def test_malformed_traceparent_starts_a_new_trace_rather_than_failing(api: ApiClient) -> None:
    resp = api.get("/health/live", auth=False, headers={"traceparent": "garbage"})
    assert resp.status == 200, (
        f"{api.impl}: a malformed traceparent produced {resp.status}. An unparsable "
        f"trace header is ignored, never fatal.\n{resp.exchange.render()}"
    )
    assert_trace_id(resp)


def test_span_id_in_traceresponse_is_not_the_inbound_one(api: ApiClient) -> None:
    """The server's span is a *child* of the caller's, not the same span."""
    trace_id = uuid.uuid4().hex
    span_id = uuid.uuid4().hex[:16]
    resp = api.get(
        "/health/live", auth=False, headers={"traceparent": f"00-{trace_id}-{span_id}-01"}
    )
    header = resp.headers.get("traceresponse")
    if header is None:
        pytest.skip(f"{api.impl} does not send traceresponse; covered by its own test")
    returned_span = header.split("-")[2]
    assert SPAN_ID_RE.match(returned_span)
    assert returned_span != span_id, (
        f"{api.impl}: the server reused the caller's span ID {span_id}. Its work is a "
        f"new span in the same trace."
    )


# ---------------------------------------------------------------------------
# RED metrics, via Prometheus
# ---------------------------------------------------------------------------


@pytest.mark.slow
@pytest.mark.timeout(180)
def test_request_duration_metric_exists_and_increments(
    api: ApiClient, prometheus: Prometheus, service_name: str
) -> None:
    """The R in RED: a request count that actually counts requests."""
    expr = f'sum({DURATION_COUNT}{{service_name="{service_name}"}})'

    before = prometheus.scalar(expr)
    if before is None:
        found = prometheus.wait_for(lambda: prometheus.scalar(expr) is not None, timeout=90)
        if not found:
            services = prometheus.label_values(DURATION_COUNT, "service_name")
            pytest.fail(
                f"{api.impl}: Prometheus has no {DURATION_COUNT} series for "
                f'service_name="{service_name}". Services reporting: '
                f"{sorted(services) or 'none'}.\n"
                f"Check OTEL_SERVICE_NAME, the OTLP endpoint, and that the collector's "
                f"prometheus exporter is scraped."
            )
        before = prometheus.scalar(expr)

    probes = 25
    for _ in range(probes):
        api.get("/health/live", auth=False)

    grew = prometheus.wait_for(
        lambda: (now := prometheus.scalar(expr)) is not None and now > (before or 0),
        timeout=120,
        interval=5,
    )
    after = prometheus.scalar(expr)
    assert grew, (
        f"{api.impl}: {probes} requests did not move {DURATION_COUNT} "
        f"({before} → {after}) within 120s. Either the metric is not recorded for "
        f"every request, or the export pipeline is not delivering "
        f"(OTEL_METRIC_EXPORT_INTERVAL is 15s in docker-compose)."
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_histogram_buckets_match_the_normative_boundaries(
    api: ApiClient, prometheus: Prometheus, service_name: str
) -> None:
    """Observability spec §5.2 / OBS3.3 — the check that makes the benchmark valid.

    A p95 read out of a histogram is an interpolation between bucket edges. Two
    services with different edges produce two numbers that cannot be compared,
    and nothing about the comparison *looks* wrong.
    """
    expr = f'{DURATION_BUCKET}{{service_name="{service_name}"}}'
    try:
        found = prometheus.wait_for(lambda: bool(prometheus.query(expr)), timeout=60)
    except PrometheusError as exc:
        pytest.fail(f"{api.impl}: {exc}")
    if not found:
        pytest.fail(
            f"{api.impl}: no {DURATION_BUCKET} series for service_name=\"{service_name}\". "
            f"Either the histogram is not exported or the service name is wrong."
        )

    observed = {_normalise_le(le) for le in prometheus.label_values(expr, "le")}
    missing = sorted(REQUIRED_LE - observed, key=lambda v: (v == "+Inf", float(v.replace("+Inf", "inf"))))
    extra = sorted(observed - REQUIRED_LE, key=lambda v: (v == "+Inf", float(v.replace("+Inf", "inf"))))
    assert not missing and not extra, (
        f"{api.impl}: histogram bucket boundaries diverge from the normative set "
        f"(observability specification §5.2).\n"
        f"  missing: {missing}\n"
        f"  extra:   {extra}\n"
        f"  required: {sorted(REQUIRED_LE, key=lambda v: (v == '+Inf', float(v.replace('+Inf', 'inf'))))}\n"
        f"Every implementation must configure the identical explicit bucket list, or "
        f"cross-language latency comparison is meaningless."
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_all_implementations_share_one_bucket_layout(prometheus: Prometheus) -> None:
    """The same check from the other direction: the five must agree with each other."""
    services = prometheus.label_values(DURATION_BUCKET, "service_name")
    known = {s for s in services if s in set(IMPL_SERVICE_NAMES.values())}
    if len(known) < 2:
        pytest.skip(
            f"only {len(known)} implementation(s) are reporting histograms "
            f"({sorted(known) or 'none'}); need at least two to compare"
        )

    layouts = {
        service: frozenset(
            _normalise_le(le)
            for le in prometheus.label_values(
                f'{DURATION_BUCKET}{{service_name="{service}"}}', "le"
            )
        )
        for service in sorted(known)
    }
    distinct = set(layouts.values())
    if len(distinct) > 1:
        report = "\n".join(
            f"  {service}: {sorted(buckets, key=lambda v: (v == '+Inf', float(v.replace('+Inf', 'inf'))))}"
            for service, buckets in layouts.items()
        )
        pytest.fail(
            "implementations do not share one histogram layout — every latency "
            f"comparison between them is invalid:\n{report}"
        )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_metric_labels_have_bounded_cardinality(
    api: ApiClient, prometheus: Prometheus, service_name: str
) -> None:
    """The cardinality guard: no user ID, task ID, email or raw path in a label.

    One unbounded label is how a metrics backend goes from cheap to unusable.
    ``http_route`` must be the *template* (``/api/v1/tasks/{id}``), never the
    concrete path.
    """
    expr = f'{DURATION_COUNT}{{service_name="{service_name}"}}'
    if not prometheus.query(expr):
        pytest.skip(f"no {DURATION_COUNT} series for {service_name} yet")

    offenders: list[str] = []
    for metric in prometheus.series_labels(expr):
        for label, value in metric.items():
            if label in CARDINALITY_EXEMPT_LABELS:
                continue
            if UUID_RE.search(value):
                offenders.append(f"{label}={value!r} (contains a UUID)")
            elif "@" in value:
                offenders.append(f"{label}={value!r} (contains an email address)")
            elif ID_PREFIX_RE.search(value):
                offenders.append(f"{label}={value!r} (contains a resource identifier)")

    assert not offenders, (
        f"{api.impl}: high-cardinality metric labels found:\n  "
        + "\n  ".join(sorted(set(offenders))[:10])
        + "\nRoutes must be templated (/api/v1/tasks/{id}) and identifiers must never "
        "become label values."
    )


@pytest.mark.slow
@pytest.mark.timeout(120)
def test_route_label_is_templated_not_concrete(
    api: ApiClient, prometheus: Prometheus, service_name: str, user: ApiClient
) -> None:
    """Directly exercises the templating: hit a parameterised route and look."""
    created = user.create_task("Metric route probe")
    created.implemented()
    if created.status == 201:
        for _ in range(3):
            user.get_task(created.task["id"])

    expr = f'{DURATION_COUNT}{{service_name="{service_name}"}}'
    prometheus.wait_for(lambda: bool(prometheus.query(expr)), timeout=60)
    routes = prometheus.label_values(expr, "http_route")
    if not routes:
        pytest.skip(f"{api.impl}: no http_route label present yet")

    concrete = sorted(r for r in routes if ID_PREFIX_RE.search(r) or UUID_RE.search(r))
    assert not concrete, (
        f"{api.impl}: http_route contains concrete paths {concrete[:5]}. Each distinct "
        f"task ID becomes a new time series — this is the classic way to blow up a "
        f"metrics backend. Use the route template."
    )
