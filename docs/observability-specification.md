# TaskFlow — Observability Specification

Companion to `requirements-specification.md`, `api-specification.md` and `database-schema.md`.
Defines the telemetry contract that **all five implementations** (Go, Rust, Python, C#, TypeScript) must satisfy identically.

> **Version note.** All versions in this document were verified in **August 2026**. Pin them in your manifests; re-verify before starting a new phase.

---

## 1. Why This Document Exists

The original requirements spec had three observability lines (NFR12–14: JSON logs, correlation IDs, health check). That is *logging*, not observability. This document replaces them.

The distinction that matters in production:

| | Question it answers | Cardinality | Cost model |
|---|---|---|---|
| **Metrics** | "Is something wrong, and how wrong?" | Low (bounded label sets) | Cheap, always-on |
| **Traces** | "Where in the request path is it wrong?" | High (per-request) | Expensive, sampled |
| **Logs** | "What exactly happened in this one case?" | Very high | Expensive, indexed by label only |
| **Profiles** | "Which line of code is burning the CPU/RAM?" | Continuous, low overhead | Cheap, always-on |

You debug **top-down**: alert fires on a metric → jump to an exemplar trace → jump to the logs correlated to that trace → jump to the profile for the same time window. Every design decision below exists to make those four jumps possible with one click.

**The core insight to internalise from this project:** correlation is not a feature you add later. It is a property of the ID plumbing you install on day one. If `trace_id` is not on every log line and every metric exemplar, you have four disconnected tools, not an observability stack.

---

## 2. Requirements

### OBS1: Instrumentation Contract

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS1.1 | All services emit traces, metrics and logs via **OpenTelemetry** to a single OTLP endpoint | High |
| OBS1.2 | Telemetry is exported over **OTLP/gRPC on port 4317** to the collector; no service talks to a storage backend directly | High |
| OBS1.3 | Services follow **OpenTelemetry Semantic Conventions** for HTTP, database and messaging attributes | High |
| OBS1.4 | Every service sets `service.name`, `service.version`, `service.instance.id` and `deployment.environment.name` resource attributes | High |
| OBS1.5 | W3C **traceparent** header is propagated inbound and outbound on every hop | High |
| OBS1.6 | Instrumentation is configurable entirely by `OTEL_*` environment variables; no code change required to change endpoint, sampling or resource attributes | Medium |
| OBS1.7 | Telemetry export failure never blocks or fails a request | High |

### OBS2: Structured Logging

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS2.1 | All logs are single-line JSON on stdout | High |
| OBS2.2 | Every log line emitted inside a request scope carries `trace_id`, `span_id` and `trace_flags` | High |
| OBS2.3 | Log levels: `debug`, `info`, `warn`, `error`; default `info` in non-dev environments | High |
| OBS2.4 | Every HTTP request produces exactly **one** access log line at completion | High |
| OBS2.5 | Logs never contain passwords, tokens, password hashes, `Authorization` headers, or full request bodies | High |
| OBS2.6 | Errors log a stack trace or equivalent under `exception.stacktrace` | Medium |
| OBS2.7 | Log volume per request is bounded — no unbounded per-item logging inside loops | Medium |

### OBS3: Metrics

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS3.1 | All services expose the **RED** metrics defined in §5.1 with identical names and label sets | High |
| OBS3.2 | Runtime/**USE** metrics (memory, GC, goroutines/tasks/threads, connection pool) are exported per §5.2 | High |
| OBS3.3 | Histogram buckets are identical across all five implementations so latency is comparable | High |
| OBS3.4 | No metric label may contain unbounded values (user ID, task ID, raw URL path, email) | High |
| OBS3.5 | HTTP metrics use `http.route` (the template, e.g. `/api/v1/tasks/:id`), never the raw path | High |
| OBS3.6 | Histograms attach **exemplars** carrying `trace_id` so a latency spike links to a trace | Medium |

### OBS4: Tracing

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS4.1 | Every inbound HTTP request produces a `SERVER` span named `{method} {http.route}` | High |
| OBS4.2 | Every database query produces a `CLIENT` child span with the statement (parameters stripped) | High |
| OBS4.3 | Every cache and message-broker operation produces a child span | High |
| OBS4.4 | Spans record `error.type` and set span status `ERROR` on failure | High |
| OBS4.5 | Sampling is **parent-based, head sampling** by default; ratio configurable, 100% in dev | High |
| OBS4.6 | The collector applies **tail sampling**: keep 100% of errors and slow requests, ratio-sample the rest | Medium |
| OBS4.7 | `trace_id` is returned to the client in the `traceresponse` header and in a **new** `meta.traceId` field | Medium |

> **`meta.traceId`, not `meta.requestId`.** The API spec defines `requestId` as `req_abc123xyz` and the conformance suite asserts `^req_[a-zA-Z0-9]+$`; a W3C trace ID is 32 lowercase hex characters with no prefix and would fail that check permanently. Keep both: `requestId` is the human-quotable support identifier, `traceId` is the key into Tempo. This is an **additive** change to the response envelope — see `requirements-addendum.md` §1.2.

### OBS5: Health and Readiness

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS5.1 | `GET /api/v1/health/live` — liveness. Returns 200 if the process is running. **No dependency checks.** | High |
| OBS5.2 | `GET /api/v1/health/ready` — readiness. Returns 200 only if DB, cache and broker are usable; 503 otherwise | High |
| OBS5.3 | `GET /api/v1/health/startup` — startup. 200 once migrations have been applied and pools are warm | Medium |
| OBS5.4 | Readiness checks are **cached for 1s** and have a hard 2s timeout so probes cannot themselves cause an outage | High |
| OBS5.5 | The existing `GET /api/v1/health` remains as an alias of `/health/ready` for backwards compatibility | Medium |

> **Why three endpoints.** A single `/health` that checks the database is the most common self-inflicted outage in production: the database blips, every replica fails its *liveness* probe simultaneously, the orchestrator kills them all, and a recoverable dependency blip becomes a total outage. Liveness must only answer "is this process wedged." Readiness answers "should I get traffic right now."

### OBS6: SLOs and Alerting

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS6.1 | Availability and latency SLOs are declared as code (§8) and rules generated, not hand-written | High |
| OBS6.2 | Alerts are **multi-window, multi-burn-rate** on error budget, not static threshold alerts | High |
| OBS6.3 | Every alert links to a runbook and to a pre-filtered dashboard | Medium |
| OBS6.4 | Only symptom-based alerts page; cause-based alerts are ticket-severity | High |

### OBS7: Continuous Profiling

| ID | Requirement | Priority |
|----|-------------|----------|
| OBS7.1 | CPU and heap profiles are collected continuously in the benchmark environment | Low |
| OBS7.2 | Profiles carry the same `service.name` labels so they join to metrics and traces | Low |

---

## 3. Reference Architecture

```
┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
│  Go      │ │  Rust    │ │  Python  │ │  C#      │ │   TS     │
│  :8001   │ │  :8002   │ │  :8003   │ │  :8004   │ │  :8005   │
└────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
     │            │            │            │            │
     └────────────┴────────────┴────────────┴────────────┘
                          │  OTLP/gRPC :4317
                          ▼
            ┌───────────────────────────────┐
            │   OpenTelemetry Collector     │
            │   (contrib, v0.158.x)         │
            │                               │
            │  receivers:  otlp             │
            │  processors: memory_limiter   │
            │              resourcedetection│
            │              tail_sampling     │
            │              batch            │
            │  exporters:  prometheusremote │
            │              otlphttp (loki)  │
            │              otlp (tempo)     │
            └───┬───────────┬───────────┬───┘
                │           │           │
       metrics  │    logs   │   traces  │
                ▼           ▼           ▼
        ┌────────────┐ ┌────────┐ ┌────────┐   ┌────────────┐
        │ Prometheus │ │  Loki  │ │ Tempo  │   │ Pyroscope  │
        │   :9090    │ │ :3100  │ │ :3200  │   │   :4040    │
        └──────┬─────┘ └───┬────┘ └───┬────┘   └──────┬─────┘
               └───────────┴──────────┴───────────────┘
                                │
                          ┌─────▼──────┐
                          │  Grafana   │
                          │   :3000    │
                          └────────────┘
```

**Why the collector is mandatory, not optional.** Without it, every one of your five services needs to know the address, auth and protocol of three storage backends, and changing your sampling rate means redeploying five services. With it, services know exactly one address. It is the single most valuable architectural pattern in this whole stack, and it costs one container.

**Alloy vs OTel Collector.** Grafana Alloy (v1.18.0) is Grafana's own distribution of the OTel Collector and is 100% OTLP-compatible. This project uses **vanilla `otel/opentelemetry-collector-contrib`** because it is vendor-neutral and its config maps 1:1 to the OTel spec you are learning. Swapping in Alloy later is a config-language translation, not an architecture change — worth doing as an exercise in Phase 8.

---

## 4. Logging Specification

### 4.1 Canonical log line

Every field name below is normative. All five implementations must produce byte-comparable structure.

```json
{
  "timestamp": "2026-08-07T12:34:56.789Z",
  "level": "info",
  "message": "http request completed",
  "service": {
    "name": "taskflow-go",
    "version": "1.0.0",
    "instance": "taskflow-go-7d4b8c9f-x2k9p"
  },
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "trace_flags": "01",
  "http": {
    "request": { "method": "POST" },
    "route": "/api/v1/tasks",
    "response": { "status_code": 201 }
  },
  "url": { "path": "/api/v1/tasks" },
  "client": { "address": "203.0.113.42" },
  "user_agent": { "original": "curl/8.6.0" },
  "duration_ms": 42.318,
  "user": { "id": "usr_abc123" },
  "request_id": "req_abc123xyz"
}
```

### 4.2 Error log line

```json
{
  "timestamp": "2026-08-07T12:34:56.789Z",
  "level": "error",
  "message": "failed to create task",
  "service": { "name": "taskflow-rust", "version": "1.0.0" },
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "error": {
    "type": "database_error",
    "code": "INTERNAL_ERROR",
    "message": "connection pool exhausted"
  },
  "exception": {
    "type": "sqlx::Error::PoolTimedOut",
    "stacktrace": "..."
  },
  "http": { "route": "/api/v1/tasks", "response": { "status_code": 500 } },
  "duration_ms": 5001.2
}
```

### 4.3 Redaction rules (normative)

These keys must **never** appear in a log line, at any nesting depth:

```
password, passwordHash, password_hash, token, accessToken, access_token,
refreshToken, refresh_token, authorization, cookie, set-cookie,
jwt_secret, api_key, secret, storage_secret_key
```

Implement redaction as a **logger-level hook or serialiser**, not by remembering not to log them at each call site. If it depends on developer discipline, it will leak.

Additional rules:

- `email` is logged only at `debug` level; at `info` and above log `user.id`.
- Request bodies are never logged. Validation errors log the **field names** that failed, never the values.
- The `Authorization` header is dropped before the log record is constructed.

### 4.4 Log levels — when to use which

| Level | Use for | Example |
|---|---|---|
| `debug` | Detail useful only while actively debugging | "cache miss for key taskflow:tasks:usr_x:page1" |
| `info` | Normal, notable events — one per request, plus lifecycle | "http request completed", "server listening on :8080" |
| `warn` | Something recovered but a human may want to know | "circuit breaker half-open", "retry 2/3 for kafka publish" |
| `error` | The request failed and a human may need to act | "database connection lost", "unhandled panic recovered" |

A 4xx is **not** an error log — a user sending a bad request is normal operation. Log 4xx at `info` with the status code, and let the metric carry the signal. Logging every 400 at `error` level is how you train a team to ignore error logs.

### 4.5 Per-language logging libraries

| Language | Library | Version (Aug 2026) | OTel bridge |
|---|---|---|---|
| Go | `log/slog` (stdlib) + `otelslog` | Go 1.22+ / `go.opentelemetry.io/contrib/bridges/otelslog` | Native handler |
| Rust | `tracing` + `tracing-subscriber` (JSON layer) | `tracing` 0.1.x | `opentelemetry-appender-tracing` (**Stable**) |
| Python | `structlog` or stdlib `logging` + JSON formatter | `structlog` 25.x | `opentelemetry-sdk` LoggingHandler (**Development**) |
| C# | `Microsoft.Extensions.Logging` + `ILogger<T>` | .NET 8/9 | `OpenTelemetry.Extensions.Hosting` (**Stable**) |
| TypeScript | `pino` | 9.x | `@opentelemetry/instrumentation-pino` (**Development**) |

> **Rust quirk worth knowing.** In `opentelemetry-rust` v0.32.0, the **Logs and Metrics** APIs/SDKs are Stable while **Traces** is still Beta — the inverse of every other language. Also, the two bridge crates are easy to confuse: `opentelemetry-appender-tracing` (in the OTel org, stable) bridges `tracing` events → OTel **logs**; `tracing-opentelemetry` (in the tokio org, v0.33.0, community-maintained) bridges `tracing` spans → OTel **traces**. You need both.

> **Logs signal maturity.** Python and Node.js still mark the OTel *logs* SDK as Development. Pragmatic approach for those two: emit JSON to stdout and let the collector's `filelog` receiver pick it up, while traces and metrics go over OTLP. Document this asymmetry — noticing that the five languages are at different maturity levels for the same spec is itself one of the more valuable lessons in this project.

---

## 5. Metrics Specification

### 5.1 RED metrics — required on every service

**RED** = Rate, Errors, Duration. These three answer "is the service healthy" for any request-driven system.

Names follow stable OpenTelemetry HTTP semantic conventions. The Prometheus-exposed name is the OTel name with `.` → `_` and unit suffix appended.

| OTel instrument | Prometheus name | Type | Unit | Labels |
|---|---|---|---|---|
| `http.server.request.duration` | `http_server_request_duration_seconds` | Histogram | s | `http_request_method`, `http_route`, `http_response_status_code`, `error_type` |
| `http.server.active_requests` | `http_server_active_requests` | UpDownCounter | {request} | `http_request_method`, `url_scheme` |
| `http.server.request.body.size` | `http_server_request_body_size_bytes` | Histogram | By | `http_request_method`, `http_route` |
| `http.server.response.body.size` | `http_server_response_body_size_bytes` | Histogram | By | `http_request_method`, `http_route` |

> Only `http.server.request.duration` is **Stable** in semconv as of Aug 2026; the other three are still Development. Use them anyway, but expect names to move — pin your semconv version and note it in each service's README.

Request *rate* and *error rate* are both derived from the duration histogram's count — you do not need separate counters:

```promql
# Rate
sum by (service_name) (rate(http_server_request_duration_seconds_count[5m]))

# Error ratio
sum by (service_name) (rate(http_server_request_duration_seconds_count{http_response_status_code=~"5.."}[5m]))
/
sum by (service_name) (rate(http_server_request_duration_seconds_count[5m]))

# p95 latency
histogram_quantile(0.95,
  sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket[5m])))
```

### 5.2 Required histogram buckets (normative)

**All five implementations must use these exact bucket boundaries.** If they differ, cross-language latency comparison is meaningless — this is the single most common mistake in benchmark projects.

```
[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]
```

These are seconds and match the OTel spec's default advice for `http.server.request.duration`. Your NFR1 target (p95 < 200 ms) sits between the 0.1 and 0.25 buckets, which gives useful resolution exactly where you need it.

> **Native histograms.** Prometheus 3.8+ marks native histograms **stable** (still opt-in via `scrape_native_histograms`; default-on in 4.0). They give exponential-bucket resolution at a fraction of the cardinality cost. Phase 8 exercise: switch one service to native histograms and compare storage and quantile accuracy against the classic buckets.

### 5.3 USE metrics — resources

**USE** = Utilisation, Saturation, Errors. RED tells you the service is slow; USE tells you which resource ran out.

| Metric | Type | Labels | Notes |
|---|---|---|---|
| `db_client_connection_count` | UpDownCounter | `pool_name`, `state` (`used`\|`idle`) | Utilisation |
| `db_client_connection_pending_requests` | UpDownCounter | `pool_name` | **Saturation — the most important number in the whole stack** |
| `db_client_operation_duration_seconds` | Histogram | `db_operation_name`, `db_collection_name` | |
| `db_client_connection_timeouts_total` | Counter | `pool_name` | Errors |
| `process_runtime_memory_bytes` | Gauge | `type` (`heap`\|`rss`\|`stack`) | |
| `process_runtime_gc_duration_seconds` | Histogram | — | Go/C#/TS; N/A for Rust |
| `process_runtime_gc_count_total` | Counter | `generation` | |
| `process_cpu_utilization_ratio` | Gauge | — | 0.0–1.0 |
| `runtime_concurrency_count` | Gauge | — | goroutines / tokio tasks / asyncio tasks / threadpool / event-loop handles |
| `runtime_event_loop_lag_seconds` | Histogram | — | Node.js and Python only — this is where async services die |

> **The lesson in `db_client_connection_pending_requests`.** When your API gets slow under load, the cause is almost never "the code is slow." It is that all 10 pool connections are checked out and 400 requests are queuing for one. Utilisation looks fine at 100% — saturation is the number that reveals the problem. Watch this metric during your Phase 9 load test and you will see it before you see the latency.

### 5.4 Business metrics

Cheap to add, and they catch failures that RED metrics do not — a deploy that silently breaks registration shows up here first.

| Metric | Type | Labels |
|---|---|---|
| `taskflow_users_registered_total` | Counter | `outcome` (`success`\|`conflict`\|`validation_error`) |
| `taskflow_logins_total` | Counter | `outcome` (`success`\|`invalid_credentials`) |
| `taskflow_tasks_created_total` | Counter | `priority` |
| `taskflow_tasks_completed_total` | Counter | `priority` |
| `taskflow_attachments_uploaded_bytes_total` | Counter | — |
| `taskflow_websocket_connections_active` | UpDownCounter | — |
| `taskflow_rate_limit_rejections_total` | Counter | `scope` (`auth`\|`tasks`\|`upload`\|`ws`) — must match the scopes in §3.6 of the infrastructure spec |

### 5.5 Cardinality rules (normative)

Metric cardinality is the number of unique label-value combinations. It multiplies. It is the single most common way to take down a Prometheus.

**Never use as a label:** user ID, task ID, attachment ID, email, raw URL path, full error message, JWT, IP address, timestamp, user agent string.

**Budget:** each service must stay under **10,000 active series**. Verify with:

```promql
count by (__name__) ({service_name="taskflow-go"})
```

Worked example of the trap:

```
http_route (20 routes) × http_request_method (5) × status_code (12) = 1,200 series  ✅
… + user_id (10,000 users)                                        = 12,000,000 series  ❌
```

Twelve million series will use tens of gigabytes of RAM and take Prometheus down. High-cardinality dimensions belong on **traces and logs**, which are designed for them — that is the whole reason the three signals are separate.

### 5.6 Exemplars

Exemplars attach a `trace_id` to individual histogram observations, so clicking a spike on a latency graph jumps straight to a trace of a slow request. This is the highest-value five lines of config in the stack.

- Prometheus: requires `--enable-feature=exemplar-storage` (still experimental as of 3.13).
- Collector: exemplars survive the `prometheusremotewrite` exporter.
- Grafana: enable the `exemplarTraceIdDestinations` field on the Prometheus datasource pointing at Tempo.

---

## 6. Tracing Specification

### 6.1 Span naming (normative)

| Operation | Span name | Kind |
|---|---|---|
| Inbound HTTP | `POST /api/v1/tasks` | SERVER |
| Outbound HTTP | `GET` | CLIENT |
| Database query | `SELECT taskflow.tasks` | CLIENT |
| Cache op | `GET` / `SETEX` | CLIENT |
| Kafka produce | `taskflow.task-events publish` | PRODUCER |
| Kafka consume | `taskflow.task-events process` | CONSUMER |
| Internal work | `auth.verify_password` | INTERNAL |

Span names must be **low cardinality** — use the route template, never the concrete path. `POST /api/v1/tasks/:id` is correct; `POST /api/v1/tasks/tsk_abc123` will destroy your trace backend's index.

### 6.2 Required span attributes

**Server spans** (stable HTTP semconv):

```
http.request.method          = "POST"
http.route                   = "/api/v1/tasks"
http.response.status_code    = 201
url.path                     = "/api/v1/tasks"
url.scheme                   = "https"
server.address               = "api.taskflow.dev"
server.port                  = 8080
client.address               = "203.0.113.42"
network.protocol.version     = "1.1"
user_agent.original          = "curl/8.6.0"
error.type                   = "VALIDATION_ERROR"   # only when status >= 400
enduser.id                   = "usr_abc123"          # custom; safe on spans, NOT on metrics
```

**Database client spans** (stable DB semconv):

```
db.system.name        = "postgresql"
db.namespace          = "taskflow_dev"
db.collection.name    = "tasks"
db.operation.name     = "SELECT"
db.query.text         = "SELECT id, title FROM tasks WHERE user_id = $1 AND deleted_at IS NULL"
db.response.status_code = "00000"
server.address        = "postgres"
server.port           = 5432
```

`db.query.text` must be the **parameterised** statement. Never the interpolated one — that is both a cardinality problem and a PII leak.

### 6.3 Sampling strategy

Two-stage, which is what production systems actually do:

**Stage 1 — head sampling in the SDK.** Parent-based, so a trace is never half-sampled across services.

```bash
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0     # dev: keep everything
# OTEL_TRACES_SAMPLER_ARG=0.1   # prod: 10%
```

**Stage 2 — tail sampling in the collector.** Head sampling is blind: it decides before it knows whether the request failed, so at 10% you throw away 90% of your errors. Tail sampling buffers the complete trace and decides after:

```yaml
tail_sampling:
  decision_wait: 10s
  num_traces: 100000
  policies:
    - name: keep-all-errors
      type: status_code
      status_code: { status_codes: [ERROR] }
    - name: keep-slow-requests
      type: latency
      latency: { threshold_ms: 500 }
    - name: keep-all-5xx
      type: numeric_attribute
      numeric_attribute:
        key: http.response.status_code
        min_value: 500
        max_value: 599
    - name: sample-the-rest
      type: probabilistic
      probabilistic: { sampling_percentage: 10 }
```

The result: 100% of errors and slow requests kept, 10% of the boring ones. That is the shape you want, and it is impossible to achieve with head sampling alone.

### 6.4 Per-language OTel packages

| Language | Core package | Version (Aug 2026) | Signal status |
|---|---|---|---|
| Go | `go.opentelemetry.io/otel` | v1.45.0 / sdk v0.67.0 | Traces ✅ Metrics ✅ Logs 🟡 Beta |
| Rust | `opentelemetry` + `opentelemetry_sdk` | 0.32.0 | Traces 🟡 Beta **Metrics ✅ Logs ✅** |
| Python | `opentelemetry-sdk` | 1.44.0 / 0.65b0 | Traces ✅ Metrics ✅ Logs 🟡 Dev |
| C# | `OpenTelemetry` (NuGet) | 1.17.0 | **All three ✅ GA** |
| TypeScript | `@opentelemetry/sdk-node` | 0.221.0 (API 1.9.1) | Traces ✅ Metrics ✅ Logs 🟡 Dev |

**Framework instrumentation:**

| Language | Packages |
|---|---|
| Go | `otelhttp`, `otelgin`, `otelpgx`, `otelsql` |
| Rust | `tracing-opentelemetry` 0.33.0 + `tower-http::trace`; manual spans for `sqlx` |
| Python | `opentelemetry-instrumentation-fastapi`, `-asyncpg`, `-sqlalchemy`, `-redis` |
| C# | `OpenTelemetry.Instrumentation.AspNetCore`, `.Http`, `.EntityFrameworkCore`, `Npgsql` built-in |
| TypeScript | `@opentelemetry/auto-instrumentations-node` 0.79.0 |

### 6.5 Auto-instrumentation — the Phase 8 experiment

Zero-code instrumentation now exists for all five, via different mechanisms. Comparing them is genuinely instructive:

| Language | Mechanism | Tool |
|---|---|---|
| Python | Runtime monkey-patching | `opentelemetry-instrument` CLI (`opentelemetry-distro` 0.65b0) |
| Node.js | Module-loader hooks | `--require @opentelemetry/auto-instrumentations-node/register` |
| C# | CLR profiler API injection | `opentelemetry-dotnet-instrumentation` v1.16.0 |
| Go | **Compile-time** `-toolexec` hook | `opentelemetry-go-compile-instrumentation` **v1.0.0** (stable July 2026) |
| Rust | None — compile-time-only language, no runtime hook point | Manual instrumentation required |
| Any (out-of-process) | eBPF, protocol-level | `opentelemetry-ebpf-instrumentation` (OBI, ex-Grafana Beyla) — alpha |

The exercise: instrument each service manually first, then add auto-instrumentation and diff the resulting spans. You will find auto-instrumentation gives excellent breadth (every HTTP and DB call) but zero business context (no `taskflow_tasks_created_total`, no `auth.verify_password` span). That trade-off — and the fact that Rust simply cannot participate — is the point.

---

## 7. Collector Configuration

`observability/otel-collector/config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 8
      http:
        endpoint: 0.0.0.0:4318

processors:
  # MUST be first. Without it the collector OOMs under load and takes
  # your telemetry down exactly when you need it most.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 20

  resourcedetection:
    detectors: [env, system, docker]
    timeout: 5s

  # Strip anything that must never reach storage.
  attributes/redact:
    actions:
      - key: http.request.header.authorization
        action: delete
      - key: password
        action: delete
      - key: refresh_token
        action: delete

  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 1000
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow
        type: latency
        latency: { threshold_ms: 500 }
      # Belt and braces: catch 5xx even if an SDK failed to set span status
      # ERROR. Given the five languages are at different OTel maturity levels,
      # do not rely on status_code alone.
      - name: errors-5xx
        type: numeric_attribute
        numeric_attribute:
          key: http.response.status_code
          min_value: 500
          max_value: 599
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }

  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

exporters:
  otlp/tempo:
    endpoint: tempo:4317
    tls: { insecure: true }

  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls: { insecure: true }

  prometheusremotewrite:
    endpoint: http://prometheus:9090/api/v1/write
    tls: { insecure: true }
    send_metadata: true
    # Deliberately false: promoting every resource attribute to a metric label
    # multiplies cardinality (see §5.5). Service identity reaches Prometheus via
    # the target_info metric instead, which is the low-cardinality way to do it.
    resource_to_telemetry_conversion: { enabled: false }
    target_info: { enabled: true }

  debug:
    verbosity: basic

extensions:
  health_check: { endpoint: 0.0.0.0:13133 }
  pprof: { endpoint: 0.0.0.0:1777 }
  zpages: { endpoint: 0.0.0.0:55679 }

service:
  extensions: [health_check, pprof, zpages]
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus: { host: 0.0.0.0, port: 8890 }
    logs: { level: info }
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, attributes/redact, tail_sampling, batch]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, attributes/redact, batch]
      exporters: [otlphttp/loki]
```

**Processor order is not stylistic — it is semantic.** `memory_limiter` must be first (it can only shed load it sees first). `batch` must be last (batching before sampling wastes work). `tail_sampling` must come before `batch` and needs complete traces, which is why it buffers for `decision_wait`.

**Collector self-monitoring.** The collector is a single point of failure for all telemetry. Scrape its own metrics on `:8890` and alert on `otelcol_processor_dropped_spans` and `otelcol_exporter_send_failed_metric_points` — a silently-dropping collector is worse than no collector, because you will trust the empty dashboard.

---

## 8. SLOs and Alerting

### 8.1 SLO definitions

| SLO | SLI | Target | Window | Error budget |
|---|---|---|---|---|
| **Availability** | non-5xx responses ÷ all responses | 99.0% | 30d rolling | 7h 12m/month |
| **Latency** | requests served < 250 ms ÷ all requests | 95.0% | 30d rolling | 36h/month |
| **Auth latency** | `/auth/*` served < 500 ms ÷ all | 99.0% | 30d rolling | 7h 12m/month |

The latency SLI measures at **250 ms**, not NFR1's 200 ms, because Prometheus can only evaluate a histogram at a bucket boundary and 200 ms falls between the 0.1 and 0.25 buckets (§5.2). This is conservative — it counts fewer requests as failures than a true 200 ms cut would. To measure 200 ms exactly, add `0.2` to the bucket list in §5.2 **in all five implementations**, or the cross-language comparison breaks.

The `/auth/*` target is deliberately looser on time: bcrypt cost factor 12 (NFR4) is *designed* to take ~250 ms. Setting the same 200 ms target for login as for `GET /tasks` would mean permanently violating an SLO by design. Choosing per-endpoint-class targets is the real skill here.

### 8.2 SLOs as code — Sloth

Use **Sloth** (`slok/sloth` v0.16.0) to generate Prometheus recording and multi-burn-rate alert rules from YAML. Hand-writing burn-rate alerts is error-prone and nobody does it twice.

`observability/slo/taskflow.yaml`:

```yaml
version: prometheus/v1
service: taskflow
labels:
  owner: backend
slos:
  - name: availability
    objective: 99.0
    description: 99% of HTTP requests succeed (non-5xx)
    sli:
      events:
        error_query: |
          sum(rate(http_server_request_duration_seconds_count{
            service_name=~"taskflow-.*", http_response_status_code=~"5.."}[{{.window}}]))
        total_query: |
          sum(rate(http_server_request_duration_seconds_count{
            service_name=~"taskflow-.*"}[{{.window}}]))
    alerting:
      name: TaskFlowAvailability
      page_alert:   { labels: { severity: page } }
      ticket_alert: { labels: { severity: ticket } }

  # NOTE: the threshold below is le="0.25", not 0.2. Prometheus histogram
  # quantiles can only be evaluated at bucket boundaries, and 200ms falls
  # between the 0.1 and 0.25 buckets (§5.2). Measuring at 250ms is the
  # closest achievable proxy for NFR1 and is deliberately conservative
  # (it counts fewer requests as failures than a true 200ms cut would).
  # If you need to measure exactly 200ms, add 0.2 to the bucket list in
  # §5.2 — in ALL FIVE implementations, or the comparison breaks.
  - name: latency-p95-250ms
    objective: 95.0
    description: 95% of requests complete within 250ms (proxy for NFR1's 200ms target)
    sli:
      events:
        error_query: |
          (
            sum(rate(http_server_request_duration_seconds_count{service_name=~"taskflow-.*"}[{{.window}}]))
            -
            sum(rate(http_server_request_duration_seconds_bucket{service_name=~"taskflow-.*", le="0.25"}[{{.window}}]))
          )
        total_query: |
          sum(rate(http_server_request_duration_seconds_count{service_name=~"taskflow-.*"}[{{.window}}]))
    alerting:
      name: TaskFlowLatency
      page_alert:   { labels: { severity: page } }
      ticket_alert: { labels: { severity: ticket } }

  # Looser target, deliberately: bcrypt cost 12 (NFR4) is DESIGNED to take
  # ~250ms. Holding /auth/* to the same latency target as GET /tasks would
  # mean permanently violating an SLO by design.
  - name: auth-latency-500ms
    objective: 99.0
    description: 99% of auth requests complete within 500ms
    sli:
      events:
        error_query: |
          (
            sum(rate(http_server_request_duration_seconds_count{
              service_name=~"taskflow-.*", http_route=~"/api/v1/auth/.*"}[{{.window}}]))
            -
            sum(rate(http_server_request_duration_seconds_bucket{
              service_name=~"taskflow-.*", http_route=~"/api/v1/auth/.*", le="0.5"}[{{.window}}]))
          )
        total_query: |
          sum(rate(http_server_request_duration_seconds_count{
            service_name=~"taskflow-.*", http_route=~"/api/v1/auth/.*"}[{{.window}}]))
    alerting:
      name: TaskFlowAuthLatency
      page_alert:   { labels: { severity: page } }
      ticket_alert: { labels: { severity: ticket } }
```

Generate with:

```bash
sloth generate -i observability/slo/taskflow.yaml -o observability/prometheus/rules/slo.yaml
```

Run this in CI and fail the build if the output differs from what is committed — generated rules must never drift from their source.

### 8.3 Why multi-burn-rate

A static alert (`error rate > 1% for 5 minutes`) has two failure modes: it pages at 3am for a 5-minute blip that consumed 0.01% of your monthly budget, and it stays silent through a 0.9% error rate that quietly eats the entire budget over two weeks.

Burn-rate alerting fixes both by asking one question instead: *how fast am I consuming my error budget?* A burn rate of 1 exhausts the budget exactly at the end of the window. A burn rate of 14.4 exhausts it in 2 days — that deserves a page.

| Severity | Long window | Short window | Burn rate | Budget consumed before firing | Action |
|---|---|---|---|---|---|
| Page | 1h | 5m | 14.4× | 2% | Wake someone |
| Page | 6h | 30m | 6× | 5% | Wake someone |
| Ticket | 1d | 2h | 3× | 10% | Next business day |
| Ticket | 3d | 6h | 1× | 10% | Next business day |

The short window is the false-positive guard: it must *also* be burning right now, which prevents a resolved incident from paging you an hour later.

### 8.4 Non-SLO alerts

Symptom-based alerts page. Cause-based alerts open tickets. The rule of thumb: if a user cannot tell the difference, it should not wake anyone.

| Alert | Expression | Severity |
|---|---|---|
| `DBPoolSaturated` | `db_client_connection_pending_requests > 0` for 5m | ticket |
| `DBPoolExhausted` | `db_client_connection_pending_requests > 20` for 2m | page |
| `CollectorDroppingSpans` | `rate(otelcol_processor_dropped_spans[5m]) > 0` | ticket |
| `HighEventLoopLag` | `histogram_quantile(0.99, runtime_event_loop_lag_seconds) > 0.1` | ticket |
| `RateLimitRejectionSpike` | `rate(taskflow_rate_limit_rejections_total[5m]) > 10` | ticket |
| `NoTelemetryReceived` | `absent(up{job="otel-collector"})` for 5m | page |
| `CertificateExpiringSoon` | `probe_ssl_earliest_cert_expiry - time() < 7*86400` | ticket |

---

## 9. Dashboards

Four dashboards, provisioned as code in `observability/grafana/dashboards/`. Never click-configure a dashboard you intend to keep.

### 9.1 `taskflow-overview.json` — the on-call dashboard
Row 1: SLO status — availability %, latency %, error budget remaining (gauges).
Row 2: RED — request rate by service, error rate by service, p50/p95/p99 latency (with exemplars enabled).
Row 3: Traffic breakdown by route and status code.

### 9.2 `taskflow-service-detail.json` — templated by `$service`
Per-service RED, DB pool utilisation and saturation, cache hit ratio, runtime memory/GC, event-loop lag, in-flight requests, top 10 slowest routes.

### 9.3 `taskflow-comparison.json` — the reason this project exists
The same five metrics for all five implementations on shared axes: p50/p95/p99 latency, throughput at fixed concurrency, RSS memory, CPU per 1k requests, cold-start time.

Read this one honestly. Rust and Go will show lower memory and tail latency; C# will surprise you on throughput; Python and TypeScript will be fine at TaskFlow's scale and will show you exactly where they stop being fine. The interesting result is not the ranking — it is *where the curves cross* and what causes each one to bend.

### 9.4 `taskflow-database.json`
Connection pool state, query duration by operation, `pg_stat_statements` top queries, index hit ratio, table/index bloat, lock waits, replication lag.

### 9.5 Datasource wiring (the part that makes it one tool instead of four)

```yaml
# observability/grafana/provisioning/datasources/datasources.yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://prometheus:9090
    jsonData:
      httpMethod: POST
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: tempo          # metric spike  → trace
  - name: Tempo
    type: tempo
    uid: tempo
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki             # trace         → logs
        filterByTraceID: true
        spanStartTimeShift: -5m
        spanEndTimeShift: 5m
      tracesToMetrics:
        datasourceUid: prometheus       # trace         → metrics
      tracesToProfiles:
        datasourceUid: pyroscope        # trace         → flamegraph
      serviceMap:
        datasourceUid: prometheus
      nodeGraph: { enabled: true }
  - name: Loki
    type: loki
    uid: loki
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: '"trace_id":"(\w+)"'
          url: '$${__value.raw}'
          datasourceUid: tempo          # log line      → trace
  - name: Pyroscope
    type: grafana-pyroscope-datasource
    uid: pyroscope
    url: http://pyroscope:4040
```

Those four cross-links are the entire payoff. Build them on day one of the observability phase, not at the end.

---

## 10. Docker Compose — Observability Stack

`docker-compose.observability.yml` (compose with the main file via `-f`):

```yaml
name: taskflow-observability

services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.158.0
    container_name: taskflow-otelcol
    command: ["--config=/etc/otelcol/config.yaml"]
    volumes:
      - ./observability/otel-collector/config.yaml:/etc/otelcol/config.yaml:ro
    ports:
      - "4317:4317"    # OTLP gRPC
      - "4318:4318"    # OTLP HTTP
      - "8890:8890"    # collector's own metrics
      - "13133:13133"  # health
      - "55679:55679"  # zpages
    depends_on: [tempo, loki, prometheus]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:13133"]
      interval: 10s
      timeout: 5s
      retries: 5

  prometheus:
    image: prom/prometheus:v3.13.2
    container_name: taskflow-prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.enable-remote-write-receiver
      - --web.enable-otlp-receiver
      - --enable-feature=exemplar-storage
      - --enable-feature=native-histograms
    volumes:
      - ./observability/prometheus:/etc/prometheus:ro
      - prometheus_data:/prometheus
    ports: ["9090:9090"]

  loki:
    image: grafana/loki:3.7.6
    container_name: taskflow-loki
    command: ["-config.file=/etc/loki/config.yaml"]
    volumes:
      - ./observability/loki/config.yaml:/etc/loki/config.yaml:ro
      - loki_data:/loki
    ports: ["3100:3100"]

  tempo:
    image: grafana/tempo:3.0.2
    container_name: taskflow-tempo
    command: ["-config.file=/etc/tempo/config.yaml"]
    volumes:
      - ./observability/tempo/config.yaml:/etc/tempo/config.yaml:ro
      - tempo_data:/var/tempo
    ports:
      - "3200:3200"    # Tempo HTTP/query
      # NOTE: Tempo's own OTLP receiver is on 4317 internally. It is deliberately
      # NOT published — services must go through the collector, never direct.

  pyroscope:
    image: grafana/pyroscope:2.0.0
    container_name: taskflow-pyroscope
    ports: ["4040:4040"]
    volumes: [pyroscope_data:/data]

  grafana:
    image: grafana/grafana:13.0.3
    container_name: taskflow-grafana
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
      GF_FEATURE_TOGGLES_ENABLE: traceqlEditor,traceToProfiles,flameGraph
    volumes:
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    ports: ["3000:3000"]
    depends_on: [prometheus, loki, tempo, pyroscope]

volumes:
  prometheus_data:
  loki_data:
  tempo_data:
  pyroscope_data:
  grafana_data:
```

**Port map** (kept consistent across every document in this set):

| Port | Service |
|---|---|
| 3000 | Grafana |
| 3100 | Loki |
| 3200 | Tempo (query) |
| 4040 | Pyroscope |
| 4317 / 4318 | OTel Collector OTLP gRPC / HTTP |
| 5432 | PostgreSQL |
| 6379 | Valkey |
| 8001–8005 | Go / Rust / Python / C# / TypeScript APIs |
| 8080 | Redpanda Schema Registry |
| 8090 | Redpanda Console |
| 8890 | OTel Collector self-metrics |
| 9090 | Prometheus |
| 9092 | Redpanda / Kafka broker |
| 8333 | S3-compatible object storage |
| 13133 / 55679 | Collector health / zpages |

---

## 11. Environment Variables

Added to `.env.example`; identical across all five services:

```bash
# ── OpenTelemetry ────────────────────────────────────────────────
OTEL_SERVICE_NAME=taskflow-go                 # per service
OTEL_SERVICE_VERSION=1.0.0
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_TIMEOUT=10000
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=development,service.namespace=taskflow

# Sampling
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0                   # 1.0 dev, 0.1 prod

# Signal toggles
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_METRIC_EXPORT_INTERVAL=15000

# Batching
OTEL_BSP_MAX_QUEUE_SIZE=2048
OTEL_BSP_SCHEDULE_DELAY=5000

# Propagation
OTEL_PROPAGATORS=tracecontext,baggage

# ── Logging ──────────────────────────────────────────────────────
LOG_LEVEL=info
LOG_FORMAT=json
LOG_SAMPLING_ENABLED=false                    # true in prod for high-volume paths

# ── Profiling ────────────────────────────────────────────────────
PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040
PYROSCOPE_APPLICATION_NAME=taskflow-go
PROFILING_ENABLED=false                       # true only in the benchmark env
```

---

## 12. Continuous Profiling

Profiling answers the question none of the other three signals can: the trace says the handler took 900 ms and the DB took 40 ms of it — so what was the other 860 ms *doing*?

- **OTel profiling signal**: still **Alpha** as of Aug 2026. Do not build on it yet; watch it.
- **Pyroscope 2.0** (GA April 2026): rewritten storage, native OTLP-profiles ingestion, ~95% smaller symbol storage. This is the practical choice today.

| Language | Agent | Notes |
|---|---|---|
| Go | `pyroscope-go` SDK, or `net/http/pprof` scraped | Best-supported; also the easiest to reason about |
| Rust | `pyroscope-rs` with `pprof-rs` backend | Needs frame pointers: build with `-C force-frame-pointers=yes` |
| Python | `pyroscope-io` (py-spy based) | Sampling profiler, low overhead |
| C# | `Pyroscope.NET` (via `dotnet-trace`) | |
| TypeScript | `@pyroscope/nodejs` | V8 CPU + heap profiler |
| Any | eBPF profiler via Grafana Alloy | No SDK, no rebuild; whole-host view |

Enable profiling **only in the benchmark environment** (`PROFILING_ENABLED=true`). Overhead is 1–3% CPU — real but acceptable; enabling it everywhere in a learning project just muddies your benchmark numbers.

---

## 13. Verification Checklist

Each implementation is not "observably complete" until every box is ticked. Run these against a live service.

**Logs**
- [ ] `docker logs taskflow-go | jq .` parses every line without error
- [ ] Every request-scoped line has a non-empty `trace_id`
- [ ] `grep -iE 'password|bearer|refresh_token' logs` returns nothing
- [ ] Exactly one access log line per request (verify with a single curl)
- [ ] A 400 logs at `info`, a 500 logs at `error`

**Metrics**
- [ ] All RED metrics present in Prometheus with the exact names in §5.1
- [ ] Histogram buckets identical across all five services (`curl … | grep 'le='` and diff)
- [ ] `count({service_name="taskflow-X"}) < 10000`
- [ ] No metric label contains a UUID or email — grep the raw exposition
- [ ] Exemplars visible on the latency panel in Grafana

**Traces**
- [ ] A single request produces a connected trace: HTTP → service → DB → cache
- [ ] Span names use route templates, never concrete IDs
- [ ] `traceparent` propagates across the WebSocket-notification path
- [ ] Failed requests set span status ERROR and record `error.type`
- [ ] Tail sampling keeps 100% of a deliberately-induced 500

**Correlation — the whole point**
- [ ] Metric spike → click exemplar → trace opens
- [ ] Trace → "Logs for this span" → correct log lines appear
- [ ] Log line → click TraceID → trace opens
- [ ] Trace → flamegraph for the same time window

**Health**
- [ ] `/health/live` returns 200 with the database stopped
- [ ] `/health/ready` returns 503 with the database stopped
- [ ] `/health/ready` recovers within 5s of the database returning
- [ ] Readiness responds in < 100 ms under load (cached, per OBS5.4)

**Failure modes**
- [ ] Stop the collector: services keep serving traffic, no errors surfaced to clients
- [ ] Restart the collector: telemetry resumes without a service restart
- [ ] Collector self-metrics show zero `otelcol_processor_dropped_spans` at steady state

---

## 14. Common Mistakes This Spec Is Designed to Prevent

| Mistake | Consequence | Prevented by |
|---|---|---|
| User ID as a metric label | Prometheus OOM at ~10k users | OBS3.4, §5.5 |
| Raw path instead of `http.route` | Unbounded cardinality; unusable dashboards | OBS3.5 |
| One `/health` that checks the DB | DB blip → all replicas killed → total outage | OBS5.1–5.2 |
| Different histogram buckets per language | Benchmark comparison is meaningless | OBS3.3, §5.2 |
| Head sampling only at 10% | 90% of errors invisible | OBS4.6, §6.3 |
| Logging 4xx at `error` | Team learns to ignore error logs | §4.4 |
| Blocking telemetry export | Collector hiccup becomes a user-facing outage | OBS1.7 |
| No `memory_limiter` in collector | Collector OOMs exactly under the load you need to observe | §7 |
| Interpolated SQL in `db.query.text` | PII leak + span cardinality explosion | §6.2 |
| Hand-written burn-rate alerts | Subtly wrong; alert fatigue | §8.2 |
| Not monitoring the collector | Silent telemetry loss; you trust an empty dashboard | §7 |

---

## Sources

- [OpenTelemetry Semantic Conventions — HTTP spans](https://opentelemetry.io/docs/specs/semconv/http/http-spans/)
- [OpenTelemetry Semantic Conventions — HTTP metrics](https://opentelemetry.io/docs/specs/semconv/http/http-metrics/)
- [OpenTelemetry Semantic Conventions — Database spans](https://opentelemetry.io/docs/specs/semconv/database/database-spans/)
- [opentelemetry-rust — signal status](https://github.com/open-telemetry/opentelemetry-rust)
- [opentelemetry-go — CHANGELOG](https://github.com/open-telemetry/opentelemetry-go/blob/main/CHANGELOG.md)
- [Go compile-time instrumentation v1.0.0](https://opentelemetry.io/blog/2026/go-compile-time-instrumentation-v1/)
- [OpenTelemetry eBPF Instrumentation (OBI) 2026 goals](https://opentelemetry.io/blog/2026/obi-goals/)
- [Prometheus native histograms specification](https://prometheus.io/docs/specs/native_histograms/)
- [Prometheus 3.13 feature flags](https://prometheus.io/docs/prometheus/3.13/feature_flags/)
- [Grafana Alloy vs OpenTelemetry Collector](https://grafana.com/oss/alloy-opentelemetry-collector/)
- [Grafana Pyroscope 2.0 release](https://grafana.com/blog/pyroscope-2-0-release/)
- [Sloth — SLO generator](https://github.com/slok/sloth)
- [Pyrra](https://github.com/pyrra-dev/pyrra)
- [OpenTelemetry Profiles specification (Alpha)](https://opentelemetry.io/docs/specs/otel/profiles/)
