# TaskFlow — Learning Roadmap

Eleven phases, buildable in one language or all five.
Every phase has a **command that tells you whether you're done**, and reference links per language.

---

## How this works

You are not writing the tests. They already exist — tagged by phase, parameterised over every language you've enabled. Your job is to make them pass.

```bash
make check PHASE=1 IMPL=go
```

```
  PHASE 1 — Core API
  ────────────────────────────────────────────────────────────
  go           ░░░░░░░░░░░░░░░░░░░░░░    0/213  213 not implemented

  First failures:
    test_phase1_auth.py::test_register_returns_201[go]
      → POST /api/v1/auth/register returned 501 NOT_IMPLEMENTED
    test_phase1_auth.py::test_register_duplicate_email_conflicts[go]
      → POST /api/v1/auth/register returned 501 NOT_IMPLEMENTED
```

Every red line is one behaviour to implement. When they're all green, that phase is done in that language — not "feels done", *is* done, against a contract you didn't get to negotiate with.

**Load testing and profiling are pre-built too.** From Phase 0 you can run `make bench-quick`, `make profile IMPL=go` and `make bench-cache`. They'll tell you the service isn't implemented yet, and then they keep working, unchanged, for the rest of the project.

**CI is not a phase.** It runs from your first commit and gets more useful as you build. You never stop to "set up CI".

---

## One language or five

Five languages is the default and it's the more interesting project. **One language is a fully supported path, not a degraded one.**

```bash
make languages LANGS=go          # just Go
make languages LANGS=go,rust     # two
make languages LANGS=all         # back to five
```

That rewrites one line in `.env`. Nothing is deleted — the other directories stay on disk — and the progress tools narrow to match: `check-phase`, `progress`, `status`. `benchmark` and `profile` deliberately do not: they default to all five because comparison is the point, so pass `IMPL=` explicitly when you are working in one language.

What you keep in solo mode: all eleven phases, every phase gate, the load harness, the cache A/B, profiling, chaos experiments, CI. What you lose: exactly one thing — `make diff`, the differential test that proves two independent implementations agree. It skips with a message explaining why rather than failing.

**Roughly what it costs**, relative to doing it once in one language:

| Languages | Phases 0–6 | All eleven phases |
|---|---|---|
| One | 1× | ~1.8× |
| Two | ~1.8× | ~3.3× |
| Five | ~4× | ~7.5× |

Not linear, because the *design* work happens once — the second language is translation, not invention. Which is also the argument for lockstep if you do go wide.

Deliberately no calendar estimates here. How long this takes depends on how much of it you already know, and a number would be either discouraging or wrong. The phase gates tell you where you are far better than a schedule would.

**An honest recommendation.** If your goal is "learn production backend development", one language gets you there. The other four teach you language idioms and give you a benchmark worth publishing — real, but a different and much more expensive lesson. Two is a good compromise: pick one you know well (fast feedback, you're learning concepts not syntax) and one that's genuinely foreign.

### If you go wide, two things make lockstep survivable

**1. Within each phase, finish one language completely first.** Resolve every design decision there, get it green, then port. The rest become translation exercises rather than parallel design problems. Rotate which language leads.

**2. Cut scope within a phase, not the phase itself.** If a phase drags, ship the core tests and defer the rest. Five implementations at 80% teaches far more than three at 100% and two abandoned.

---

## What you're up against

Tests per phase, **per language**, with a rough sense of relative size:

| Phase | | Tests | Size | | Phase | | Tests | Size |
|---:|---|---:|---|---|---:|---|---:|---|
| 0 | Scaffold ✅ | 35 | — | | 6 | Events & the outbox | 13 | ▓▓▓░░ |
| 1 | Core API | 213 | ▓▓▓▓▓ | | 7 | Security | 37 | ▓▓░░░ |
| 2 | Observability | 12 | ▓▓▓░░ | | 8 | Load & profiling | tooling | ▓▓░░░ |
| 3 | Database depth | 11 | ▓▓░░░ | | 9 | Real-time | 8 | ▓▓░░░ |
| 4 | Caching & rate limiting | 15 | ▓▓▓░░ | | 10 | Object storage | 29 | ▓░░░░ |
| 5 | Resilience | 17 | ▓▓░░░ | | 11 | Synthesis | — | ▓░░░░ |

Size is relative effort, not a schedule — Phase 1 is roughly five times Phase 10, and that ratio holds whoever you are. Absolute time depends entirely on how much of this you already know.

Phases 8 and 11 have no assertions because "is this profile good?" and "is this write-up honest?" aren't booleans. They're gated on tooling output instead — `make bench`, `make soak`, `make profile`.

Note the shape: **Phase 1 is 213 tests and Phase 6 is 13.** That is not a difficulty ranking. Phase 1 is broad and mechanical — many endpoints, many validation rules, each individually easy. Phase 6 is thirteen tests because distributed correctness is hard to assert and easy to get subtly wrong. Every one of those thirteen will take real thought to pass. Don't read test count as effort.

### Reading each phase

- **Build** — what to implement
- **Concepts** — what it teaches, especially what's counter-intuitive
- **Gate** — the command that decides
- **Also run** — the load/profiling/chaos commands that become meaningful here
- **References** — per language, verified links
- **Traps** — mistakes that are easy to make and hard to find

---
## Phase 0 — Scaffold ✅ *(already built)*

Nothing to do. Verify it works:

```bash
make setup && make up && make check PHASE=0
```

Green rows — one per language you've enabled. You have: Postgres 17 with migrations applied, Valkey with the rate-limiter function loaded and the event streams created, S3 storage with a bucket, the full observability stack, and your services answering health probes.

The default stack is about 400 MB idle. There's no message broker in it — Phase 6 runs on Valkey Streams, which is the same container Phase 4 already needs.

**Read the code you've been given.** `go/cmd/server/main.go` and its four siblings are ~300 lines each and show the shape everything else hangs off: config from env, pooled DB connection, three health endpoints, graceful shutdown, JSON logging.

**What already works today:**

```bash
make status                 # what's up
make bench-quick IMPL=go    # says "returns 501 — implement Phase 1 first"
make profile IMPL=go        # captures a real (boring) flamegraph
make chaos 3                # DB down → liveness passes, readiness fails
make migrate-test           # up → down → up leaves an identical schema
```

Chaos experiment 3 passing on the skeleton is worth pausing on. It's the single most important resilience property in the project, and you get it for free because the skeletons split liveness from readiness correctly.

---


## Phase 1 — Core API

**Build.** Every endpoint in `docs/openapi.yaml` except attachments and WebSocket: register, login, refresh, logout, me, profile, and full task CRUD with pagination, filtering, sorting and soft deletes. Standard response envelope. Every error code. bcrypt cost 12. JWT access + refresh.

**Concepts.** Layered architecture and why the handler/service/repository boundary earns its keep. How each language models errors — Go's `error` values, Rust's `Result` + `thiserror`, Python exceptions, C#'s exceptions, TypeScript discriminated unions. This is the most illuminating comparison in the entire project; write it down as you go, it's the raw material for your final write-up. Ownership enforced **in the query**, never by post-fetch comparison.

**Gate**

```bash
make check PHASE=1 IMPL=go       # 213 tests
make check PHASE=1               # all five
make diff                        # do all five return identical shapes?
```

**Also run**

```bash
make seed SIZE=small
make bench-quick IMPL=go         # first real numbers
```

**References**

| | HTTP | DB driver | JWT | Validation | Password |
|---|---|---|---|---|---|
| **Go** | [chi](https://go-chi.io/) | [pgx v5](https://pkg.go.dev/github.com/jackc/pgx/v5) | [golang-jwt v5](https://pkg.go.dev/github.com/golang-jwt/jwt/v5) | [validator/v10](https://pkg.go.dev/github.com/go-playground/validator/v10) | [x/crypto/bcrypt](https://pkg.go.dev/golang.org/x/crypto/bcrypt) |
| **Rust** | [axum](https://docs.rs/axum/latest/axum/) · [tokio](https://docs.rs/tokio/latest/tokio/) | [sqlx](https://docs.rs/sqlx/latest/sqlx/) | [jsonwebtoken](https://docs.rs/jsonwebtoken/latest/jsonwebtoken/) | [validator](https://docs.rs/validator/latest/validator/) | [bcrypt](https://docs.rs/bcrypt/latest/bcrypt/) |
| **Python** | [FastAPI](https://fastapi.tiangolo.com/) · [uvicorn](https://www.uvicorn.org/) | [asyncpg](https://magicstack.github.io/asyncpg/current/) | [PyJWT](https://pyjwt.readthedocs.io/en/stable/) | [Pydantic v2](https://pydantic.dev/docs/validation/latest/get-started) | [bcrypt](https://pypi.org/project/bcrypt/) |
| **C#** | [Minimal APIs](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis) | [Npgsql](https://www.npgsql.org/doc/index.html) | [JwtBearer](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/jwt-authn) | [FluentValidation](https://docs.fluentvalidation.net/en/latest/) | [BCrypt.Net-Next](https://github.com/BcryptNet/bcrypt.net) |
| **TypeScript** | [Hono](https://hono.dev/) | [postgres.js](https://github.com/porsager/postgres) · [drizzle](https://orm.drizzle.team/) | [jose](https://github.com/panva/jose) | [zod](https://zod.dev/) | [bcrypt](https://www.npmjs.com/package/bcrypt) |

> **Python note:** `passlib` has been unmaintained since 2020. Use the `bcrypt` package directly.

**Traps**

- The response envelope drifting. C# will emit `2026-08-15T00:00:00` where everyone else emits `…000Z`. `make diff` catches it; your eyes will not.
- Returning **403** instead of **404** for another user's task. 403 leaks existence. There are tests for this on GET, PUT and DELETE.
- Fetch-then-compare ownership instead of `WHERE user_id = $1`. One forgotten check from full IDOR.
- Forgetting `WHERE deleted_at IS NULL` on exactly one query.
- The `dueDate` in the past rule is an **application** check — the database constraint was deliberately removed (see `migrations/001`, and the README for why).

---


## Phase 2 — Observability

Second, before any performance work. Everything after this is measurement-driven.

**Build.** OTel SDK in all five, exporting traces, metrics and logs over OTLP to the collector on `:4317`. The RED metrics with **identical histogram buckets**. Logs carrying `trace_id`. `meta.traceId` on every response.

**Concepts.** The four signals and what each is for. **Cardinality** — `user_id` as a metric label is a production incident at ~10k users. The collector as an indirection layer: five services, one address. Why `http.route` and never the raw path.

**Gate**

```bash
make up-full                 # observability stack now needed
make check PHASE=2
```

The Phase 2 tests do something unusual: they query **Prometheus directly** and assert that your histogram bucket boundaries are byte-identical across all five implementations. If they diverge, every benchmark you run from here on is meaningless — so this is a hard gate, not a nicety.

**Also run**

```bash
open http://localhost:3000   # Grafana — the four cross-links are pre-wired
```

Click a latency spike → exemplar → trace → logs → flamegraph. That chain is the entire payoff.

**Then, in the same phase — SLOs and sampling.** These used to be a separate "advanced observability" phase. They're 200 lines of config, not a phase of work, and they belong next to the instrumentation they measure.

```bash
make slo                          # generate burn-rate rules from observability/slo/taskflow.yaml
curl localhost:9090/api/v1/rules  # they should be there
make chaos N=6                    # collector down → zero user-visible impact
```

Tail sampling is already configured in the collector — verify it works by inducing errors at a 10% baseline sample rate and confirming 100% of them survive. That's the point of tail sampling: head sampling at 10% throws away 90% of your errors, because it decides before it knows the request failed.

Error budgets are the concept worth sitting with. A 99% availability target over 30 days is 7h 12m of downtime you are *allowed* to spend. Burn rate asks how fast you're spending it: 14.4× exhausts a month's budget in two days, which is why that's the standard page threshold. It replaces "error rate > 1% for 5 minutes", which both pages at 3am for a blip that cost 0.01% of the budget and stays silent through a slow bleed that eats all of it.

**References**

| | OTel docs | Getting started | HTTP instrumentation |
|---|---|---|---|
| **Go** | [languages/go](https://opentelemetry.io/docs/languages/go/) | [guide](https://opentelemetry.io/docs/languages/go/getting-started/) | [otelhttp](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp) |
| **Rust** | [languages/rust](https://opentelemetry.io/docs/languages/rust/) | [guide](https://opentelemetry.io/docs/languages/rust/getting-started/) | [tower-http TraceLayer](https://docs.rs/tower-http/latest/tower_http/trace/index.html) |
| **Python** | [languages/python](https://opentelemetry.io/docs/languages/python/) | [guide](https://opentelemetry.io/docs/languages/python/getting-started/) | [instrumentation-fastapi](https://opentelemetry-python-contrib.readthedocs.io/en/latest/instrumentation/fastapi/fastapi.html) |
| **C#** | [languages/dotnet](https://opentelemetry.io/docs/languages/dotnet/) | [guide](https://opentelemetry.io/docs/languages/dotnet/getting-started/) | [Instrumentation.AspNetCore](https://www.nuget.org/packages/OpenTelemetry.Instrumentation.AspNetCore) |
| **TypeScript** | [languages/js](https://opentelemetry.io/docs/languages/js/) | [guide](https://opentelemetry.io/docs/languages/js/getting-started/nodejs/) | [instrumentation-http](https://www.npmjs.com/package/@opentelemetry/instrumentation-http) |

SLOs and sampling: [Sloth](https://github.com/slok/sloth) · [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) · [OTel tail sampling processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)

Semantic conventions: [HTTP spans](https://opentelemetry.io/docs/specs/semconv/http/http-spans/) · [HTTP metrics](https://opentelemetry.io/docs/specs/semconv/http/http-metrics/) · [Database spans](https://opentelemetry.io/docs/specs/semconv/database/database-spans/)

> **Rust will take longest here, and the reason is interesting.** In `opentelemetry-rust`, Logs and Metrics are Stable while **Traces is still Beta** — the inverse of every other language. You need two separate bridge crates that are easy to confuse: [`opentelemetry-appender-tracing`](https://docs.rs/opentelemetry-appender-tracing/latest/opentelemetry_appender_tracing/) (in the OTel org — `tracing` events → OTel **logs**) and [`tracing-opentelemetry`](https://docs.rs/tracing-opentelemetry/latest/tracing_opentelemetry/) (in the **tokio** org — `tracing` spans → OTel **traces**). There is no official axum OTel instrumentation package; the standard pattern is `tower-http::TraceLayer` + `tracing` + the bridge.

**Traps.** Raw path instead of `http.route` (unbounded cardinality). Logging the interpolated SQL rather than the parameterised statement — both a PII leak and a cardinality explosion. Blocking on telemetry export, so a collector hiccup becomes a user-facing outage.

---


## Phase 3 — Database Depth

The highest-value non-obvious phase. Most "slow API" problems are database problems.

**Build.** Tuned pools. `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`. The pool metrics. `EXPLAIN (ANALYZE, BUFFERS)` on every list query. Keyset pagination alongside OFFSET. Deliberately introduce an N+1, watch the trace show 101 spans, then fix it.

**Concepts.** Why `OFFSET 10000` is O(n) and keyset pagination is O(1). Which of your indexes the planner actually uses — some won't be; drop them. **Saturation vs utilisation**: `db_client_connection_pending_requests` moves *before* latency does.

**Gate**

```bash
make seed SIZE=large         # 1000 users × 100 tasks
make check PHASE=3
```

**Also run**

```bash
make bench IMPL=go
make profile IMPL=go
make lint-migrations
```

**The experiment worth doing.** Run the same load test at pool sizes 5, 10, 25 and 100. Plot p99. The curve is not monotonic — bigger pools are often *slower*, because Postgres peaks at roughly `(2 × cores) + spindles` active connections and past that you're paying for context switching and lock contention. When your service is slow and the pool is saturated, the reflex is to raise the pool size, and that usually makes it worse.

**References**

| | Pool configuration |
|---|---|
| **Go** | [pgxpool](https://pkg.go.dev/github.com/jackc/pgx/v5/pgxpool) |
| **Rust** | [PgPoolOptions](https://docs.rs/sqlx/latest/sqlx/postgres/type.PgPoolOptions.html) |
| **Python** | [asyncpg pools](https://magicstack.github.io/asyncpg/current/api/index.html#connection-pools) |
| **C#** | [Npgsql pooling](https://www.npgsql.org/doc/connection-string-parameters.html) |
| **TypeScript** | [postgres.js connection options](https://github.com/porsager/postgres#connection-details) |

Language-neutral: [EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html) · [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) · [Number Of Database Connections](https://wiki.postgresql.org/wiki/Number_Of_Database_Connections) (the pool-sizing formula)

---


## Phase 4 — Caching & Rate Limiting

**Build.** Cache-aside on the read endpoints, with a stampede lock and TTL jitter. Set-based invalidation. The GCRA rate limiter — the Lua function is already written and loaded, you're calling `FCALL ratelimit`. Refresh-token denylist. Cache metrics.

**Concepts.** Cache-aside, and why you **delete rather than update** on invalidation. The stampede, demonstrated. Why in-process rate limiting is wrong the moment you have two replicas. Bounded staleness as a deliberate trade rather than a bug.

**Gate**

```bash
make check PHASE=4
```

**Also run — this is the phase that pays off the harness**

```bash
make bench-cache IMPL=go
```

This runs your service twice with identical load — once with `CACHE_ENABLED=false`, once `true` — and reports p50/p95/p99, throughput at p95<200ms, **actual database query counts** from `pg_stat_statements`, cache hit ratio, and where the two latency curves diverge as arrival rate climbs.

The single most convincing number it produces is usually the query count. Something like *"database queries dropped 87%"* is a far better answer to "was the cache worth it?" than a latency percentile, and the ramp variant shows the crossover — caching often barely matters at low load and matters enormously past the knee. That crossover is the real lesson, and a single-point comparison hides it.

```bash
make profile-diff IMPL=go
```

Profiles with cache off vs on and highlights which stack frames disappeared. You will see the query-execution and row-scanning frames collapse. This is the direct link between "we added Redis" and "here is what stopped happening."

**Do the two-replica test**

```bash
docker compose up -d --scale go-api=2
make check PHASE=4 IMPL=go
```

If your rate limiter passes single-replica and fails at two, you've learned this phase's entire lesson in one command. Each replica independently allows 100, so the real limit is 100 × replicas.

**References**

| | Client |
|---|---|
| **Go** | [valkey-go](https://pkg.go.dev/github.com/valkey-io/valkey-go) · [rueidis](https://pkg.go.dev/github.com/redis/rueidis) |
| **Rust** | [redis-rs](https://docs.rs/redis/latest/redis/) |
| **Python** | [redis-py async](https://redis.readthedocs.io/en/stable/examples/asyncio_examples.html) |
| **C#** | [StackExchange.Redis](https://stackexchange.github.io/StackExchange.Redis/) |
| **TypeScript** | [iovalkey](https://github.com/valkey-io/iovalkey) · [ioredis](https://github.com/redis/ioredis) |

Language-neutral: [Redis Functions](https://redis.io/docs/latest/develop/programmability/functions-intro/) · [Redis rate-limiting guide](https://redis.io/docs/latest/develop/use-cases/rate-limiter/) · `infrastructure/valkey/functions/ratelimit.lua` (commented; read it)

**Traps.** Caching before the DB commit. Updating instead of deleting on invalidation. Forgetting `VALKEY_COMMAND_TIMEOUT_MS`, so a slow cache becomes a slow API — the cache turns into a *source* of latency.

---


## Phase 5 — Resilience

**Build.** Explicit timeouts on every outbound call, budgeted so each layer is shorter than its caller. Retry with **full jitter** and a retry budget. Circuit breakers on Valkey and Postgres. Concurrency limiting and load shedding. `Idempotency-Key`.

**Concepts.** Timeout budgets. Full jitter — "backoff plus a bit of jitter" still herds; randomising across the whole interval is what actually spreads retries. Retry budgets preventing amplification (3 retries = 4× traffic at exactly the worst moment). The circuit breaker's real purpose: not detecting failure, but *not consuming resources* on a call you know will fail.

**Gate**

```bash
make check PHASE=5
for n in 1 2 3 4 6 8; do make chaos N=$n; done
```

Experiments 5 and 7 need the broker and object storage, which arrive in Phases 6 and 11.

**References**

| | Retry | Circuit breaker |
|---|---|---|
| **Go** | [failsafe-go](https://pkg.go.dev/github.com/failsafe-go/failsafe-go) | [sony/gobreaker](https://pkg.go.dev/github.com/sony/gobreaker) |
| **Rust** | [backon](https://docs.rs/backon/latest/backon/) | [tower](https://docs.rs/tower/latest/tower/) layers |
| **Python** | [tenacity](https://tenacity.readthedocs.io/en/latest/) | [pybreaker](https://github.com/danielfm/pybreaker) |
| **C#** | [Polly v8](https://www.pollydocs.org/) | [Http.Resilience](https://learn.microsoft.com/en-us/dotnet/core/resilience/) |
| **TypeScript** | [p-retry](https://github.com/sindresorhus/p-retry) | [cockatiel](https://github.com/connor4312/cockatiel) |

Essential reading: [AWS — Exponential backoff and jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)

> Worth noticing when you compare the five: Polly v8's resilience pipelines are more mature and more ergonomic than anything in the other four ecosystems, and .NET ships first-party integration for it. "The platform already solved this" is exactly the kind of difference a five-language project exists to surface.

---


## Phase 6 — Events & the Outbox

**Build.** Outbox rows written in the same transaction as the data. A polling relay using `FOR UPDATE SKIP LOCKED`. Event envelope carrying `traceId`. Three consumers — notification, audit, analytics — reading a **Valkey Stream** consumer group with explicit `XACK`. Idempotency via `processed_events`. A DLQ for poison messages.

The tables (`outbox`, `processed_events`, `audit_log`) already exist — migration 002 applied them on day one. The streams and consumer groups are created by `valkey-streams-init` on `make up`.

> **This phase used to be built on Kafka, and was several times the size.** The reasoning for the change is worth stating: the *concepts* here — dual writes, at-least-once delivery, idempotent consumers, acknowledgement, redelivery, dead-lettering — are the valuable part, and Valkey Streams teaches every one of them. Kafka adds a broker, a gigabyte of RAM, and a different client library in every language, in exchange for partitioning and log compaction that a single-service task app has no use for. Adding it here was over-engineering. It's now §4.9 of the infrastructure spec, as an appendix, for when you want the real thing.

**Concepts.** Write the naive version first:

```
tx.begin(); tx.insert(task); tx.commit()
events.publish(event)         // ← what if this fails? or the process dies here?
```

Reason through all four outcomes. Two of them are silent, permanent inconsistency, and swapping the order just changes which one you get. That's the **dual-write problem**, and it has no solution using two systems and one code path. The outbox is the resolution: the event becomes a row in the *same* transaction, and a separate relay moves it out.

Then the idea to take away from the whole project: **at-least-once delivery + idempotent consumer = exactly-once processing.** Exactly-once *delivery* does not exist in distributed systems. Anyone who tells you their system has it is describing this construction.

The Streams mechanics map onto Kafka almost one-to-one, which is the point:

| Valkey Streams | Kafka |
|---|---|
| stream | topic |
| consumer group | consumer group |
| pending entries list (PEL) | uncommitted offsets |
| `XACK` | offset commit |
| `XAUTOCLAIM` | rebalance / partition reassignment |
| `MAXLEN ~` | retention |
| *(no partitions)* | partitions |

That last row is the honest limitation, and worth understanding rather than glossing: no partitions means no horizontal ordering guarantee beyond a single stream, no log compaction, and memory-bound rather than disk-bound retention. The infrastructure spec §4.8 says plainly when a real project should reach for Kafka instead.

**Gate**

```bash
make check PHASE=6            # 13 tests
make chaos N=5                # transport down → writes still succeed
```

The chaos experiment is the one that matters. Stop Valkey, keep writing tasks: every `POST /tasks` still returns 201 and the outbox backlog grows. Restart it, and the backlog drains with nothing lost. That property — the write path surviving the transport being down — is what the outbox buys you, and you can watch it happen.

**Traps.** Publishing from the handler (the exact thing you're avoiding). Acknowledging on receipt rather than after processing. Inserting into `processed_events` outside the transaction that holds the side effect, which makes it do nothing at all. Forgetting `XAUTOCLAIM`, so a consumer that dies mid-message leaves that entry stuck in the PEL forever.

**References**

Valkey Streams is the same client you already wired up in Phase 4 — no new dependency:

| | Streams API |
|---|---|
| **Go** | [valkey-go](https://pkg.go.dev/github.com/valkey-io/valkey-go) — `XAdd`, `XReadGroup`, `XAck`, `XAutoClaim` |
| **Rust** | [redis-rs streams](https://docs.rs/redis/latest/redis/streams/index.html) |
| **Python** | [redis-py](https://redis.readthedocs.io/en/stable/commands.html#redis.commands.core.CoreCommands.xadd) |
| **C#** | [StackExchange.Redis streams](https://stackexchange.github.io/StackExchange.Redis/Streams) |
| **TypeScript** | [iovalkey](https://github.com/valkey-io/iovalkey) |

Command reference: [XADD](https://valkey.io/commands/xadd/) · [XGROUP CREATE](https://valkey.io/commands/xgroup-create/) · [XREADGROUP](https://valkey.io/commands/xreadgroup/) · [XACK](https://valkey.io/commands/xack/) · [XAUTOCLAIM](https://valkey.io/commands/xautoclaim/) · [XPENDING](https://valkey.io/commands/xpending/)

Patterns: [Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html) · [Redis Streams intro](https://redis.io/docs/latest/develop/data-types/streams/)

**Optional appendix — do it again with Kafka.** If you want the real broker, infrastructure spec §4.9 has it: Redpanda behind a compose profile, topics, partition keys, per-language clients, Debezium CDC, schema registry. Everything you learned on Streams transfers directly.

```bash
docker compose -f docker-compose.infra.yml --profile kafka up -d
pytest -m appendix --kafka-brokers localhost:9092
```


## Phase 7 — Security Hardening

**Build.** Dummy-hash timing defence on login. Full JWT validation with a **pinned** algorithm. Refresh-token families with reuse detection (migration 003 already added the columns). Security headers. Magic-byte file validation. SOPS + age for secrets.

**Concepts.** Timing attacks and user enumeration — the naive login returns in ~1 ms for an unknown email and ~250 ms for a wrong password, and that difference enumerates your entire user base. The **algorithm-confusion attack**: an attacker takes your public RS256 key (public by definition), signs a token with it as HS256, and if your library reads the algorithm from the token's own header, it verifies. Token families as the OAuth 2.1 answer to theft.

**Gate**

```bash
make check PHASE=7
```

The login-timing test samples 30 unknown-email and 30 wrong-password attempts and asserts the medians are within 30%. It takes about 6 minutes because it must respect your own 10/min auth rate limit — which is a nice demonstration that your Phase 4 work is real.

**References.** [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x00-header/) · [OWASP JWT Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_Cheat_Sheet.html) · [OWASP Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html) · [RFC 9700 — OAuth 2.0 Security BCP](https://www.rfc-editor.org/rfc/rfc9700)

Scanning per language: [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) · [cargo-audit / RustSec](https://rustsec.org/) · [bandit](https://bandit.readthedocs.io/en/latest/) · [NuGet auditing](https://learn.microsoft.com/en-us/nuget/concepts/auditing-packages) · [npm audit](https://docs.npmjs.com/cli/v11/commands/npm-audit)

> Context worth knowing: EU Cyber Resilience Act vulnerability-reporting obligations began **11 September 2026**. Not applicable to a learning project, but it means teams are implementing exactly this pipeline right now — unusually current portfolio material.

---


## Phase 8 — Load Testing & Profiling

**The phase the whole project exists for.** The harness is already built; this phase is about running it properly and reading the output honestly.

**Do.**

```bash
make seed SIZE=large
make bench IMPL=all              # three runs each, median + variance, fair rules enforced
make soak IMPL=go                # 1 hour — the only test that finds leaks
make profile IMPL=all
make bench-cache IMPL=all        # the cache story, across all five
```

`benchmark.sh` refuses to produce results if the fair-comparison rules are violated: it verifies identical resource limits via `docker inspect`, discards a 60-second warm-up (JIT runtimes are materially slower cold), restores identical seeded data, runs one service at a time, and records the environment.

**Concepts.** **Coordinated omission** — read [`benchmarks/README.md`](../benchmarks/README.md) before trusting any number. Finding the knee rather than the maximum. Reading a flamegraph: wide means time spent, not depth.

**Read the results honestly.** The headline ranking is the least interesting output. What matters: where each curve bends and why; how much of TaskFlow's p50 is Postgres (identical for all five); that memory differences are larger and far more consistent than throughput differences; and that at 500 RPS all five are fine — language choice only starts mattering at a scale you'd have to justify.

**Continuous profiling.** Pyroscope has been running since Phase 0. Wire the SDK in and you get flamegraphs joined to traces by time and service — click a slow span, see what the CPU was doing. The OTel profiling signal is still Alpha as of Aug 2026, so Pyroscope's own SDKs are the practical route.

Worth knowing: profiling overhead is 1–3% CPU. Real, but acceptable — except in the benchmark environment, where it muddies your numbers. That's why `PROFILING_ENABLED` defaults to false.

**References.** [k6 constant-arrival-rate](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/) · [ramping-arrival-rate](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/ramping-arrival-rate/)

Pyroscope: [language SDKs](https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/) · [OTel Profiles spec (Alpha)](https://opentelemetry.io/docs/specs/otel/profiles/)

Profiling: [Go pprof](https://pkg.go.dev/runtime/pprof) · [pprof-rs](https://docs.rs/pprof/latest/pprof/) · [flamegraph-rs](https://github.com/flamegraph-rs/flamegraph) · [py-spy](https://github.com/benfred/py-spy) · [dotnet-trace](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-trace) · [dotnet-counters](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-counters) · [Node --cpu-prof](https://nodejs.org/api/cli.html#--cpu-prof)

---


## Phase 9 — Real-Time at Scale

**Build.** WebSocket endpoint. Valkey pub/sub fan-out. Heartbeat with idle disconnect. Per-user connection limits. Backpressure on slow consumers. SSE fallback. Graceful close (1001) on shutdown.

**Concepts.** **Build the naive in-process connection map first, then scale to two replicas and watch the notification vanish.** User A connects to replica 1, creates a task via replica 2, replica 2 has no socket for A. Everything looks fine in dev with one instance. That's the lesson.

Redis pub/sub is fire-and-forget — a disconnected subscriber misses messages permanently. For live notifications that's fine (the client refetches). Knowing when a problem needs durability instead is a real skill; Redis Streams sit in between.

**Gate**

```bash
make check PHASE=9
docker compose up -d --scale go-api=2 && make check PHASE=9 IMPL=go
```

**References.** [gorilla/websocket](https://pkg.go.dev/github.com/gorilla/websocket) · [coder/websocket](https://pkg.go.dev/github.com/coder/websocket) · [axum ws](https://docs.rs/axum/latest/axum/extract/ws/index.html) · [FastAPI WebSockets](https://fastapi.tiangolo.com/advanced/websockets/) · [ASP.NET Core WebSockets](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/websockets) · [Hono WebSocket helper](https://hono.dev/docs/helpers/websocket)

> The sharpest comparison in the project. Goroutine-per-connection, tokio tasks, asyncio, .NET thread pool, and Node's single event loop diverge more on 5,000 idle connections than on any other workload here. Measure RSS per connection.

---


## Phase 10 — Object Storage

**Build.** Multipart upload. Presigned PUT/GET as a second path. `pending_uploads` + orphan reaper. Magic-byte validation. Attachment events.

S3 storage has been running since Phase 0 — bucket created, credentials in `.env`.

**Concepts.** Measure, don't assert: **50 concurrent 10 MB multipart uploads vs 50 presigned.** Watch RSS. Then notice what presigning introduces — step 2 succeeds, step 3 never happens, and you have an orphan nobody knows about. Every optimisation moves the problem somewhere; noticing where is the skill.

**Gate**

```bash
make check PHASE=10
make chaos N=7                   # storage down → attachments 503, tasks unaffected
```

**References.** [aws-sdk-go-v2 s3](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/s3) · [PresignClient](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/s3#PresignClient) · [aws-sdk-s3 (Rust)](https://docs.rs/aws-sdk-s3/latest/aws_sdk_s3/) · [boto3 S3](https://docs.aws.amazon.com/boto3/latest/reference/services/s3.html) · [boto3 presigned URLs](https://docs.aws.amazon.com/boto3/latest/guide/s3-presigned-urls.html) · [AWS SDK for .NET](https://docs.aws.amazon.com/sdk-for-net/v4/developer-guide/welcome.html) · [@aws-sdk/client-s3](https://www.npmjs.com/package/@aws-sdk/client-s3) · [SeaweedFS S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)

---


## Phase 11 — Synthesis

Write it up. This is what converts all that work into something you can show, and something you'll still remember a year from now.

**Produce.** Root README with architecture diagrams. A per-language README covering idioms, surprises, and what you'd do differently. The benchmark report with methodology stated in full. Runbooks for each alert. ADRs for the ten decisions you'd have to defend in an interview.

**The write-up is the deliverable.** "I built the same API five times" is a claim. "Here is the p99 curve for each, here is where it bends, here is why, and here is the methodology — including how I avoided coordinated omission" is evidence.

---

## Where to stop

| After | You have | Honest description |
|---|---|---|
| Phase 2 | Working, fully instrumented APIs | "I can build and operate a production-shaped service" |
| Phase 5 | + resilience, conformance in CI | "I understand how services fail and how to stop the cascade" |
| **Phase 6** | + correctness guarantees across a transport boundary | **"I can reason about distributed correctness"** — the strongest signal here |
| Phase 8 | + a rigorous benchmark | "I can measure honestly, including the mistakes most benchmarks make" |
| Phase 11 | Everything, written up | A portfolio piece that is genuinely uncommon |

**If you pick one stopping point, stop after Phase 6.** Phases 0–6 cover almost everything that separates production backend work from tutorial backend work. Everything after is depth and polish.

---

## What this roadmap deliberately does not include

An earlier draft had fourteen phases. Four things were cut, and the reasoning is worth reading — deciding what *not* to build is most of engineering judgement.

### Cut: Kafka as a required dependency → now an appendix

Kafka on a single-service CRUD app is over-engineering, and adding it because it's on job descriptions is how projects get abandoned. What's genuinely valuable is the **transactional outbox** and everything around it: dual writes, at-least-once delivery, idempotent consumers, dead-lettering. Valkey Streams teaches all of it, on a container you already run, with a client you already wired up in Phase 4. Kafka adds a broker, ~1 GB of RAM, and a different client library per language — in exchange for partitioning and log compaction that this app has no use for.

It's still there when you want it: infrastructure spec §4.9, behind a compose profile.

```bash
docker compose -f docker-compose.infra.yml --profile kafka up -d
pytest -m appendix --kafka-brokers localhost:9092
```

### Cut: Kubernetes deployment *(was Phase 12)*

High effort for the return, and it teaches you about Kubernetes rather than about your application. The genuinely valuable part — that liveness must not check the database, or a recoverable blip becomes a total outage — you already prove in Phase 5 with `make chaos N=3`, without a cluster.

If you want it later, the shape is: kind cluster, Kustomize base plus overlays, probes wired to the three health endpoints, `preStop` and `terminationGracePeriodSeconds` matching your shutdown sequence, resource requests vs limits, PodDisruptionBudget, Argo CD. The gate that matters: stop Postgres and confirm pods stay `Running` while leaving the Service endpoints.

References if you do: [Probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/) · [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) · [Kustomize](https://kubectl.docs.kubernetes.io/references/kustomize/) · [Argo CD](https://argo-cd.readthedocs.io/en/stable/getting_started/)

### Cut: data at scale *(was Phase 13)*

Partitioning, archival, read replicas, pgbouncer. Real skills, but they only bite at a scale you'd have to justify, and Phase 3 already teaches you to read a query plan and size a pool — which is what actually goes wrong in practice.

`make seed SIZE=huge` still generates 10M tasks if you want to explore it. The interesting question if you do: which of the five language clients break under pgbouncer transaction mode, and why. (Prepared statements are the usual casualty.)

### Merged: "advanced observability" *(was Phase 8)*

SLOs, burn-rate alerts and tail sampling are about 200 lines of config, not a phase of work, and they belong next to the instrumentation they measure — so they're now the second half of Phase 2. Continuous profiling moved to Phase 8, next to the load testing that gives it something to profile. Two side-quests were dropped entirely: swapping Grafana Alloy in for the collector, and diffing auto-instrumentation against manual spans. Both are interesting afternoons; neither is a phase.

### Kept, despite being arguable

**WebSocket real-time (Phase 9).** It's in the original requirements, and it contains the single best "your code is silently broken at two replicas" lesson in the project. It's also where the five-language comparison is sharpest — goroutines, tokio tasks, asyncio, the .NET thread pool and Node's single event loop diverge more on 5,000 idle connections than on any other workload.

**Attachments and object storage (Phase 10).** Small, and the presigned-URL memory demonstration is genuinely visceral — 50 concurrent 10 MB uploads through your process versus around it.

---

## How projects like this usually die

| Failure | Signal | Response |
|---|---|---|
| One language falls behind | `make progress` shows the same red column three phases running | Timebox it, or `make languages LANGS=` to drop it honestly |
| Perfectionism in Phase 1 | Polishing code the tests already pass | `make check PHASE=1` green **is** the definition of done |
| Infrastructure sprawl | Laptop unusable, iteration slows | `make up-one IMPL=go` |
| Benchmark rabbit hole | Tuning to chase a number rather than understand one | Three runs, publish the median, note the caveats, move on |
| Losing the thread | Can't remember why a decision was made | ADRs. One page, written at the time |
| Stalling on Rust | Phases 2 and 6 take far longer there than elsewhere | Expected. Budget for it rather than reading it as failure |

The most common outcome for a project like this is quiet abandonment with three languages half-finished. The defences are all in place: `make check` gives objective done-ness, `make progress` shows visible movement, `make languages` lets you narrow scope without admitting defeat, and cutting scope *within* a phase is always available.
