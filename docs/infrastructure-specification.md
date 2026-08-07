# TaskFlow — Infrastructure Specification

Caching, distributed coordination, event streaming and object storage.
Companion to `requirements-specification.md` and `observability-specification.md`.

> **Version note.** All versions verified **August 2026**. Three of the recommendations here changed materially in the last 18 months (Redis licensing, MinIO archival, KafkaJS abandonment) — do not carry over guidance from older tutorials.

---

## 1. Answering "Redis? Kafka?" Directly

**Redis/Valkey: yes, five times over. Kafka: no — not for a project this shape.**

**Valkey is table stakes.** Nearly every production backend has one. It solves five problems in TaskFlow that you cannot solve well with Postgres alone, and each one teaches a distinct distributed-systems concept:

| Use | Phase | Concept it teaches | Effort |
|---|---|---|---|
| Rate limiting | 4 | Atomicity across processes; why `INCR` beats `SELECT`-then-`UPDATE` | Small |
| Cache-aside | 4 | Cache invalidation, stampedes, staleness, hit-ratio economics | Small |
| Refresh-token denylist | 4 | Why stateless JWTs can't be revoked, and what it costs to fix that | Small |
| Pub/sub for WebSocket fan-out | 4 | Why in-memory state breaks the moment you run two replicas | Medium |
| **Streams for the event outbox** | **6** | **Durable log, consumer groups, acknowledgement, at-least-once + idempotency** | Medium |

The fourth item is the one that changes how you think: your WebSocket implementation works perfectly on one instance and is silently broken on two. Discovering that yourself is worth more than reading about it. The fifth is the hardest correctness reasoning in the project, and it is §4.

**Kafka is genuinely optional, and it lives in §4.9.** It is not a better Redis or a faster
queue — it is a *durable, replayable, ordered, partitioned log*, and it exists to decouple
services that do not exist in this project. What Phase 6 actually teaches is the
**transactional outbox**, and Valkey Streams teaches every part of that on the container you
already run for Phase 4. The reasoning is §4.1, the term-by-term Kafka mapping is §4.2, the
trade-offs and the point at which a real project should stop and go get Kafka are §4.8.
Redpanda is still in `docker-compose.infra.yml` behind the `kafka` profile, and does not
start by default.

### What else you should learn — the honest ranked list

You asked what else. Ranked by *value per hour spent* for someone learning production backend:

| Rank | Topic | Why it beats the alternatives | Phase |
|---|---|---|---|
| 1 | **Observability** | You cannot operate what you cannot see. Everything else is guessing. | 2 |
| 2 | **Connection pooling & DB tuning** | The #1 cause of real production latency. `EXPLAIN ANALYZE`, N+1, index choice, pool sizing. | 3 |
| 3 | **Valkey: caching + rate limiting** | Universal, immediately useful, teaches atomicity | 4 |
| 4 | **Resilience: timeouts, retries, breakers** | The difference between a degraded service and a cascading outage | 5 |
| 5 | **CI/CD + Testcontainers** | Compounds — every later phase is faster once this exists | 5 |
| 6 | **Event-driven + transactional outbox** | The hardest correctness reasoning in the whole project. On Valkey Streams; Kafka is an optional appendix (§4.9). | 6 |
| 7 | **Security hardening + supply chain** | Increasingly a hiring filter; CRA reporting obligations start Sept 2026 | 7 |
| 8 | **Load testing & profiling** | Where the five-language comparison finally pays off | 9 |
| 9 | **Kubernetes** | High effort, and less differentiating than the eight above | 10 |

**Deliberately left out**, and why: gRPC (adds a protocol, teaches little new after REST+WebSocket here), GraphQL (a frontend concern), service mesh (solves a problem you won't have with one service), Elasticsearch (Postgres full-text search already covers TaskFlow's needs — you already have the GIN index), microservice decomposition (splitting a CRUD app into services teaches distributed debugging pain without the benefit).

---

## 2. Requirements

### INF1: Caching and Coordination (Valkey/Redis)

| ID | Requirement | Priority |
|----|-------------|----------|
| INF1.1 | Task list responses are cached with a **cache-aside** strategy, TTL 60s | High |
| INF1.2 | Cache entries are invalidated on any write to the owning user's tasks | High |
| INF1.3 | Rate limiting (FR5.1) is enforced in the cache layer, not per-process memory | High |
| INF1.4 | Rate limiter state is atomic across all replicas of a service | High |
| INF1.5 | Revoked refresh tokens are added to a denylist with TTL = remaining token lifetime | High |
| INF1.6 | WebSocket events fan out via pub/sub so any replica can deliver to any connection | High |
| INF1.7 | Cache unavailability degrades to origin (DB) — it never fails a request | High |
| INF1.8 | Cache keys follow the namespacing scheme in §3.3 | Medium |
| INF1.9 | Cache hit ratio, latency and evictions are exported as metrics | Medium |
| INF1.10 | Stampede protection: at most one origin fetch per key per TTL window | Medium |

### INF2: Event Streaming (Valkey Streams; Kafka optional, §4.9)

| ID | Requirement | Priority |
|----|-------------|----------|
| INF2.1 | Domain events are published for every task and attachment mutation | Medium |
| INF2.2 | Events are published via the **transactional outbox** pattern — never directly from the HTTP handler | High |
| INF2.3 | Events carry the versioned envelope of §4.4, including `traceId` and `spanId` | Medium |
| INF2.4 | Events for one user are delivered in the order they were written | High |
| INF2.5 | Consumers are idempotent — reprocessing an event must be a no-op | High |
| INF2.6 | Poison messages go to a dead-letter stream after N deliveries, never blocking the consumer | High |
| INF2.7 | Consumer lag and pending-entry count are exported as metrics and alerted on | Medium |
| INF2.8 | Transport unavailability does not fail the write path (the outbox absorbs it) | High |
| INF2.9 | Entries are acknowledged only after the work is durable, and a sweeper reclaims a dead consumer's pending entries | High |

### INF3: Object Storage

| ID | Requirement | Priority |
|----|-------------|----------|
| INF3.1 | Attachments (FR4) are stored in S3-compatible object storage, never in Postgres | High |
| INF3.2 | Uploads use **presigned PUT URLs** — bytes never transit the API process | Medium |
| INF3.3 | Downloads use presigned GET URLs with 15-minute expiry | Medium |
| INF3.4 | Object keys are unguessable (`attachments/{task_id}/{uuid}/{filename}`) | High |
| INF3.5 | Orphaned objects (upload started, DB row never created) are reaped after 24h | Low |

---

## 3. Valkey / Redis

### 3.1 Which one — and why this is not the obvious answer

Redis's licence changed twice in two years. The current state:

- **March 2024**: Redis Ltd. moved core Redis off BSD-3-Clause to dual RSALv2/SSPLv1 — neither OSI-approved. The Linux Foundation forked the last BSD commit as **Valkey**.
- **May 2025**: Redis 8.0 added **AGPLv3** as a third option, so Redis is now tri-licensed (RSALv2 **or** SSPLv1 **or** AGPLv3).
- **August 2026**: Valkey is at **9.1**, governed by the Linux Foundation, still BSD-3-Clause. AWS ElastiCache and Aiven now default new provisioning to Valkey.

**This spec targets Valkey 9.** Reasoning: BSD-3-Clause is permissive with no network-copyleft ambiguity; it is wire-compatible with Redis (RESP2/RESP3) so every command and client carries over; and the managed-cloud providers have already moved. Redis 8 under AGPLv3 is a perfectly reasonable alternative for a learning project — AGPL's network clause only bites if you offer the software itself as a service. Avoid the RSALv2/SSPLv1 paths for anything you intend to redistribute.

Practically: **everything in this document works unchanged on either.** Swap the image and you're done. Knowing *why* there are two projects is the part worth carrying forward.

### 3.2 Client libraries (verified Aug 2026)

| Language | Recommended | Version | Alternative | Notes |
|---|---|---|---|---|
| Go | `github.com/valkey-io/valkey-go` | v1.0.76 | `github.com/redis/go-redis/v9` v9.22.0 | `valkey-go` and `rueidis` (now in the Redis org, v1.0.76) share a lineage: mandatory auto-pipelining, RESP3 client-side caching. `go-redis` is more familiar and simpler to read. |
| Rust | `redis` (redis-rs) | 1.5.0 | `fred` 10.1.0 | **Prefer redis-rs.** `fred` has not published to crates.io since Feb 2025 — check its GitHub activity before depending on it. |
| Python | `redis` (redis-py) | 8.1.0 | `valkey` (valkey-py) 6.1.1 | Use `redis.asyncio`. valkey-py is an API-compatible fork. |
| C# | `StackExchange.Redis` | 3.1.13 | `Valkey.Glide` 1.1.0 | StackExchange is mature with a huge ecosystem. A first-party .NET Valkey client now exists. |
| TypeScript | `iovalkey` | 0.4.0 | `ioredis` 6.0.0, `redis` (node-redis) 6.2.0 | `iovalkey` is the Valkey-org fork of `ioredis`, drop-in. |

### 3.3 Key namespacing (normative)

```
taskflow:{env}:{domain}:{identifier}[:{qualifier}]
```

| Purpose | Key | Type | TTL |
|---|---|---|---|
| Task list page | `taskflow:dev:tasks:usr_abc123:list:{query_hash}` | String (JSON) | 60s |
| Single task | `taskflow:dev:tasks:tsk_abc123` | String (JSON) | 300s |
| User profile | `taskflow:dev:users:usr_abc123` | String (JSON) | 300s |
| Cache index (for invalidation) | `taskflow:dev:tasks:usr_abc123:keys` | Set | 3600s |
| Rate limit | `taskflow:dev:ratelimit:{scope}:{identifier}` | Hash (GCRA) | window |
| Token denylist | `taskflow:dev:denylist:rft:{token_sha256}` | String | token TTL |
| Stampede lock | `taskflow:dev:lock:{original_key}` | String (NX) | 5s |
| WS pub/sub channel | `taskflow:dev:events:user:usr_abc123` | Channel | — |
| Idempotency record | `taskflow:dev:idem:{key}` | String | 24h |

`{query_hash}` is `sha256(canonical_json(query_params))[:16]` — the canonicalisation matters, otherwise `?page=1&status=pending` and `?status=pending&page=1` produce different cache entries for identical results.

### 3.4 Cache-aside, correctly

The naive version has three bugs. Here is the version that doesn't:

```
READ:
  1. GET key
  2. HIT  → return
  3. MISS → SET lock:key with NX EX 5
       a. acquired → query DB → SETEX key ttl±jitter → SADD index-set → DEL lock → return
       b. not acquired → sleep 50ms, retry GET (max 3) → on exhaustion, query DB directly
                         (never fail the request just because you lost a lock race)

WRITE:
  1. Commit to DB   ← always first
  2. SMEMBERS index-set → DEL all listed keys → DEL index-set
  3. Failure of step 2 is logged and swallowed. TTL is the backstop.
```

The three bugs it fixes:

**Stampede.** A popular key expires; 500 concurrent requests all miss and all hit the database at once. The `NX` lock means exactly one goes to the database. This is the single most common cause of "the cache made things worse."

**TTL jitter.** Cache 1,000 keys at startup with identical 60s TTLs and all 1,000 expire in the same second, forever, in lockstep. Use `ttl × (0.9 + rand()×0.2)`.

**Invalidate-then-write ordering.** Writing to the cache before the DB commit means a rollback leaves a lie in the cache. Always DB first, then invalidate. And **delete, don't update** — a concurrent writer can interleave an update such that the cache holds a value the database never had.

> **The deeper point.** You cannot make cache-aside perfectly consistent. There is always a window where a reader loaded from the DB, a writer committed and invalidated, and then the reader writes its now-stale value into the cache. You *shrink* the window (short TTLs, delete-don't-update, invalidate after commit) and you accept it. Understanding that this is a bounded-staleness tradeoff rather than a bug to be fixed is the actual lesson — and it is exactly why the alternative pattern exists (§3.5).

### 3.5 What to cache — and what not to

| Endpoint | Cache? | Reasoning |
|---|---|---|
| `GET /tasks` (list) | ✅ 60s | Highest volume, tolerates 60s staleness |
| `GET /tasks/:id` | ✅ 300s | Cheap, high hit ratio |
| `GET /auth/me` | ✅ 300s | Called on nearly every page load |
| `GET /tasks/:id/attachments` | ✅ 300s | Rarely changes |
| `POST/PUT/DELETE` anything | ❌ | Writes invalidate, they don't populate |
| `POST /auth/login` | ❌ | Never cache authentication |
| `/health/*` | ❌ | Caching a health check defeats its purpose |

**Target hit ratio: > 80%** on list endpoints under the Phase 8 load profile. Below ~50%, the cache is costing you a network round-trip on every miss and buying nothing — measure before you assume it helps. Reporting "we added caching" without the hit ratio is how teams ship negative-value optimisations.

### 3.6 Distributed rate limiting

FR5.1 requires 100 req/min per user. The trap: an in-process counter works perfectly in dev and breaks the moment you run two replicas — each replica independently allows 100, so the real limit is 100 × replicas. Rate limiting must be **shared state**.

**Algorithm: GCRA** (Generic Cell Rate Algorithm), a leaky bucket that stores one timestamp instead of a list.

| Algorithm | Memory/key | Burst handling | Boundary bug |
|---|---|---|---|
| Fixed window | 1 int | Poor | ❌ 2× limit at the boundary |
| Sliding window log | N timestamps | Exact | ✅ |
| Sliding window counter | 2 ints | Approximate | ✅ |
| Token bucket | 2 fields | Configurable | ✅ |
| **GCRA** | **1 timestamp** | **Smooth** | ✅ |

GCRA wins on memory (O(1), one field) and gives smooth pacing rather than allowing a full burst at each window start. It also yields an exact `Retry-After` for free, which the API spec requires in the 429 body.

**Implementation: a Lua script registered as a Redis Function.** Redis has no built-in rate-limit command as of Aug 2026 — Redis's own official tutorial recommends `EVAL`'d Lua precisely because `MULTI/EXEC` can't branch on intermediate reads and `WATCH` causes retry storms under contention. Registering it as a **Function** (Redis 7+) gives you versioning and replication of the script itself.

> Do **not** use `redis-cell`. The module is in best-effort maintenance and its author has stated he is no longer actively developing it. Script-based GCRA needs no module compilation and runs on stock Valkey.

`infrastructure/valkey/functions/ratelimit.lua`:

```lua
#!lua name=taskflow

-- GCRA rate limiter.
-- KEYS[1] = rate limit key
-- ARGV[1] = period_ms   (window, e.g. 60000)
-- ARGV[2] = limit       (e.g. 100)
-- ARGV[3] = now_ms      (caller's clock — see note below)
-- ARGV[4] = cost        (usually 1)
-- returns { allowed(0|1), remaining, retry_after_ms, reset_after_ms }

local function ratelimit(keys, args)
  local key       = keys[1]
  local period_ms = tonumber(args[1])
  local limit     = tonumber(args[2])
  local now_ms    = tonumber(args[3])
  local cost      = tonumber(args[4]) or 1

  local emission  = period_ms / limit          -- ms per unit of quota
  local delay_tol = period_ms                  -- burst tolerance == full window

  local tat = tonumber(redis.call('GET', key)) or now_ms
  if tat < now_ms then tat = now_ms end

  local new_tat    = tat + (emission * cost)
  local allow_at   = new_tat - delay_tol
  local diff       = now_ms - allow_at

  if diff < 0 then
    local retry_after = -diff
    local remaining   = math.floor((delay_tol - (tat - now_ms)) / emission)
    return { 0, math.max(0, remaining), math.ceil(retry_after),
             math.ceil(tat - now_ms) }
  end

  redis.call('SET', key, new_tat, 'PX', math.ceil(delay_tol + emission))
  local remaining = math.floor(diff / emission)
  return { 1, remaining, 0, math.ceil(new_tat - now_ms) }
end

redis.register_function('ratelimit', ratelimit)
```

Load once at startup:

```bash
valkey-cli -x FUNCTION LOAD REPLACE < infrastructure/valkey/functions/ratelimit.lua
```

Call from any language:

```
FCALL ratelimit 1 taskflow:dev:ratelimit:tasks:usr_abc123 60000 100 <now_ms> 1
```

> **Clock note.** Passing `now_ms` from the caller means five services with skewed clocks compute different windows. The alternative — `redis.call('TIME')` inside the script — used to make scripts non-deterministic and unreplicatable; with Redis Functions and effect-based replication this is now safe, and is the better choice for production. Passing the client clock is shown here because it makes the script trivially unit-testable. **Pick one and use it identically in all five implementations**, or your rate-limit conformance tests will disagree for reasons that take a day to find.

Scopes per the API spec:

| Scope | Key (full form, per INF1.8) | Limit |
|---|---|---|
| `auth` | `taskflow:{env}:ratelimit:auth:{ip}` | 10/min |
| `tasks` | `taskflow:{env}:ratelimit:tasks:{user_id}` | 100/min |
| `upload` | `taskflow:{env}:ratelimit:upload:{user_id}` | 20/min |
| `ws` | `taskflow:{env}:ratelimit:ws:{user_id}` | 5 concurrent |

Unauthenticated requests key on IP; authenticated on user ID (a user behind a shared NAT should not be limited by their neighbours).

Response headers on every rate-limited endpoint:

```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1691409600
Retry-After: 45          # only on 429
```

### 3.7 Refresh-token denylist

JWTs are stateless — that is the whole point, and it is also why logout (FR1.5) is hard. You cannot un-issue a token. Options:

1. Look up every refresh token in Postgres — correct, and it's what the schema already does via `refresh_tokens.revoked_at`. One DB round-trip per refresh.
2. Keep a denylist in Valkey with TTL equal to the token's remaining life — sub-millisecond, self-cleaning.
3. Both: Valkey as a fast negative cache in front of Postgres as the source of truth. ✅

Option 3 is what to implement. On logout: `SETEX denylist:rft:{sha256(token)} {remaining_seconds} "1"` and set `revoked_at` in Postgres in the same transaction path. On refresh: check the denylist first (fast reject), then Postgres (authoritative).

Note that the *access* token remains valid until it expires — up to 15 minutes after logout. That is an inherent property of stateless tokens, not a bug in your implementation, and the mitigation is the short expiry you already specified. Document it; interviewers ask about it.

### 3.8 Pub/sub for WebSocket fan-out

**The bug you will find in Phase 4.** Your Phase 3 WebSocket implementation almost certainly keeps connections in a process-local map. Run two replicas: user A connects to replica 1, creates a task via replica 2 — replica 2 has no connection for A, so the notification silently vanishes. Everything looks fine in dev with one instance.

The fix: replicas coordinate through pub/sub.

```
Task mutation on any replica:
  1. Commit to Postgres
  2. PUBLISH taskflow:dev:events:user:{user_id} {json_event}

Every replica:
  - SUBSCRIBE taskflow:dev:events:user:* (or per-user on connect)
  - On message → deliver to any locally-held sockets for that user
```

Trade-off worth internalising: **pub/sub is fire-and-forget.** A disconnected subscriber misses messages permanently — there is no replay, no acknowledgement, no record that anyone was listening. For live notifications that is acceptable (the client refetches on reconnect), and it is why fan-out uses `PUBLISH` rather than something durable.

When you *do* need durability, the answer is **Streams** on the same instance (`XADD`/`XREADGROUP`/`XACK`) — that is Phase 6, §4. Recognising which of the two a problem needs is a real skill, and the two live one command apart, which makes the comparison unusually cheap to run yourself.

### 3.9 Cache metrics

| Metric | Type | Labels |
|---|---|---|
| `cache_operations_total` | Counter | `operation` (`get`\|`set`\|`del`), `result` (`hit`\|`miss`\|`error`) |
| `cache_operation_duration_seconds` | Histogram | `operation` |
| `cache_invalidations_total` | Counter | `reason` |
| `cache_stampede_lock_waits_total` | Counter | `outcome` (`acquired`\|`waited`\|`fell_through`) |
| `ratelimit_decisions_total` | Counter | `scope`, `decision` (`allow`\|`deny`) |

Hit ratio: `rate(cache_operations_total{result="hit"}[5m]) / rate(cache_operations_total{operation="get"}[5m])`

### 3.10 Configuration

```yaml
# docker-compose.infra.yml (excerpt)
valkey:
  image: valkey/valkey:9.1-alpine
  container_name: taskflow-valkey
  command: >
    valkey-server
    --maxmemory 256mb
    --maxmemory-policy volatile-lru
    --appendonly no
    --save ""
  ports: ["6379:6379"]
  healthcheck:
    test: ["CMD", "valkey-cli", "ping"]
    interval: 10s
    timeout: 3s
    retries: 5
```

**The eviction policy changed, and the reason is worth following.** The obvious setting for a cache is `allkeys-lru`: evict the coldest key under memory pressure, because the default `noeviction` starts returning OOM errors on write, which for a cache is exactly the wrong failure mode.

But from Phase 6 this instance also holds the event **streams** (§4.3), and a stream is not cache — evicting it loses events. `volatile-lru` restricts eviction to keys that carry a TTL. Every cache key here has one (§3.3) and streams have none, so the eviction candidates end up being precisely the keys that are safe to lose, and the cache still degrades gracefully under pressure.

This is a dev-stack compromise, and you should know its shape: with one instance, a memory spike still costs you cached data, and a bug that filled RAM with untagged keys would bring back the OOM-on-write failure. **In production, run streams on their own instance** — different durability settings, different memory policy, different blast radius. Mixing cache and durable data in one process is a convenience, not a design.

```bash
# .env additions
VALKEY_URL=redis://valkey:6379/0
VALKEY_POOL_SIZE=10
VALKEY_CONNECT_TIMEOUT_MS=1000
VALKEY_COMMAND_TIMEOUT_MS=200
CACHE_ENABLED=true
CACHE_TTL_TASK_LIST=60
CACHE_TTL_TASK=300
CACHE_TTL_USER=300
CACHE_TTL_JITTER_PCT=20
RATE_LIMIT_ENABLED=true
```

**`VALKEY_COMMAND_TIMEOUT_MS=200` is a load-bearing number.** With no timeout, a slow cache turns into a slow API, and INF1.7 (cache never fails a request) is violated in the worst way — the cache becomes a *source* of latency rather than a mitigation. 200 ms is already 40× a healthy p99; if you exceed it, going to the database directly is strictly better.

---

## 4. Event Streaming — the Outbox on Valkey Streams

### 4.1 Why there is no broker here any more

An earlier draft of this document put Apache Kafka (via Redpanda) in Phase 6 and admitted, in the same paragraph, that adding a broker to a single-service CRUD app is over-engineering. It was right about that and wrong to do it anyway.

Look at what the phase is actually for. The lesson is the **transactional outbox**: the dual-write problem, at-least-once delivery, idempotent consumers, exactly-once *processing*. Teaching that needs four things from the transport — a durable append-only log, consumer groups, explicit acknowledgement, and a way to redeliver what a dead consumer never finished. It does not need partitions, ISR, KRaft, tiered storage, a schema registry, or a different client library in five languages.

**Valkey Streams gives you all four**, in the container you already run for Phase 4 caching, through the Redis client each language already has wired up. `XADD` appends. `XGROUP CREATE` makes a consumer group. `XREADGROUP` delivers and tracks. `XACK` acknowledges. The pending-entries list is your uncommitted work, `XAUTOCLAIM` recovers a dead consumer's share of it, and a dead-letter queue is just another stream. The concepts map onto Kafka one-for-one (§4.2), which means the transfer is real and not a consolation prize.

What you save is not trivial: ~1 GB of RAM, a 20-second startup on every `docker compose up`, five more client dependencies to version-track, and a second thing to be down at 3am. What you give up is listed honestly in §4.8, along with the point at which a real project should stop reading this section and go get Kafka.

If you want the broker anyway — and doing it once is genuinely worth it — §4.9 is the appendix. Redpanda is still in `docker-compose.infra.yml`; it just sits behind a compose profile now and does not start by default.

**The database schema does not change either way.** `outbox`, `processed_events` and `audit_log` (§7) contain no reference to Kafka or to Valkey — they are transport-agnostic by design, and that is a feature worth noticing rather than an accident. It is also the reason the appendix is cheap: switching `EVENTS_BACKEND` from `streams` to `kafka` touches the relay and the consumer loop and nothing else.

### 4.2 Streams ↔ Kafka, term by term

| Valkey Streams | Apache Kafka | Notes |
|---|---|---|
| Stream (`taskflow:dev:events:task`) | Topic | A key in the keyspace vs. a directory of segment files. |
| Entry, id `1786128832215-0` | Record, offset `4711` | The Streams id is `<ms>-<seq>` — time-ordered and globally unique, where an offset is only meaningful per partition. |
| — (a stream is one log) | Partition | **The real difference.** See §4.8. |
| Consumer group (`XGROUP CREATE`) | Consumer group | Same idea: each group sees every entry once, independently of other groups. |
| Consumer name inside the group | Member / `client.id` | Must be unique per process; it is what `XPENDING` blames. |
| `XADD` | `produce` | |
| `XREADGROUP … >` | `poll()` with `auto.offset.reset=latest` | `>` means "entries never delivered to this group". |
| Pending Entries List (PEL) | Fetched-but-uncommitted offsets | Per-consumer, inspectable with `XPENDING`. Kafka's equivalent lives in the client's memory; the PEL lives in the server, which is strictly easier to debug. |
| `XACK` | `commitSync()` / offset commit | Both must happen **after** the work is durable. |
| `XAUTOCLAIM` after `min-idle-time` | Rebalance on session timeout | Kafka does it for you when a member's heartbeat lapses; Streams makes you run a sweeper. Explicit, but nothing happens on its own. |
| `MAXLEN ~ N` on `XADD` | `retention.ms` / `retention.bytes` | Trim by count at write time vs. delete by age in the background. |
| `XINFO GROUPS … lag` | consumer lag | Same metric, same alert. |
| `XRANGE` from `0` | seek to offset 0 and replay | Replay is a plain range read — one of the nicer things about Streams. |
| `XADD` to `…:dlq` | produce to `.dlq` topic | Identical pattern; a DLQ is not a broker feature in either system. |
| — | Log compaction (`cleanup.policy=compact`) | No equivalent. §4.8. |
| — | Schema Registry | No equivalent. §4.8. |

If you learn the left column you can read the right column. The reverse is also true, which is the whole argument.

### 4.3 Streams: naming, creation and trimming

Streams follow the same namespacing as every other key (§3.3):

| Stream | Carries | Consumer groups |
|---|---|---|
| `taskflow:{env}:events:task` | `task.*` | `taskflow.notifications`, `taskflow.audit`, `taskflow.analytics` |
| `taskflow:{env}:events:attachment` | `attachment.*` | `taskflow.reaper`, `taskflow.audit` |
| `taskflow:{env}:events:user` | `user.*` | `taskflow.audit` |
| `taskflow:{env}:events:task:dlq` | poison messages | `taskflow.dlq-review` (human) |

Three streams rather than one, split by aggregate, for the same reason Kafka splits topics: a consumer that only cares about attachments should not have to read and discard every task event.

**Creating them.** `XGROUP CREATE <stream> <group> <id> MKSTREAM` creates the stream if it is missing, so one command makes both. The `valkey-streams-init` service in `docker-compose.infra.yml` runs it for every stream/group pair on `up`, mirroring what `redpanda-init` did for topics. It is idempotent: a second run fails with `BUSYGROUP`, which is ignored.

**`$` vs `0` is the one argument to get right.**

```
XGROUP CREATE taskflow:dev:events:task taskflow.audit 0  MKSTREAM   # all history
XGROUP CREATE taskflow:dev:events:task taskflow.audit $  MKSTREAM   # only new entries
```

`0` is correct for the application's groups. The init container is not guaranteed to run before the first `XADD` — on a second `docker compose up` the relay may already have published while the group was missing — and with `$` those entries are skipped **silently**, which is data loss that looks like success. `0` replays them, and replaying is safe by construction: delivery is at-least-once and the consumers are idempotent (§4.6). It is exactly Kafka's `auto.offset.reset=earliest` vs `latest`, and the reasoning is identical.

Use `$` only for a group that must not see history: an observer, a debug tail, a conformance probe.

**Ids: `*` or explicit.** `XADD stream * field value` lets the server assign `<ms>-<seq>`, which is what you want. You *can* pass an explicit id, and it is tempting to pass the event's own identity to get free deduplication — do not. `XADD` rejects any id equal to or lower than the stream's top id, so a clock going backwards, a rewound VM, or two producers racing all turn into hard write failures on a path whose entire job is not to fail. Deduplicate at the consumer, where the answer is a `processed_events` row, not an error.

**Trimming.** Streams are **memory-bound**, not disk-bound. A stream nobody trims grows until it hits `maxmemory`, at which point either it gets evicted (silent data loss) or writes start failing. So every `XADD` carries a cap:

```
XADD taskflow:dev:events:task MAXLEN ~ 100000 * eventId evt_… payload {…}
```

The `~` matters. Exact `MAXLEN 100000` walks the radix tree on every write to remove precisely the right number of entries; `MAXLEN ~ 100000` trims only whole macro nodes, so it removes *at least* nothing and keeps *at least* 100 000, in O(1)-ish time. You will see `XLEN` sit somewhere above the cap. That is correct behaviour, not a bug.

Related, and easy to get wrong: this Valkey instance runs `--maxmemory-policy volatile-lru`, not `allkeys-lru`. Streams have no TTL; cache keys all do (§3.3). Under `allkeys-lru` a memory spike would be free to evict your event log to make room for cached task lists. Under `volatile-lru` the eviction candidates are exactly the keys that are safe to lose. In production, put streams on their own instance and stop reasoning about it (§4.8).

### 4.4 Event envelope

```json
{
  "eventId": "evt_01J8XQZ4K5N6P7R8S9T0V1W2X3",
  "eventType": "task.created",
  "eventVersion": "1.0",
  "occurredAt": "2026-08-07T12:34:56.789Z",
  "producer": "taskflow-go@1.0.0",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
  "spanId": "00f067aa0ba902b7",
  "subject": { "type": "task", "id": "tsk_abc123" },
  "actor":   { "type": "user", "id": "usr_abc123" },
  "data": {
    "id": "tsk_abc123",
    "userId": "usr_abc123",
    "title": "Complete project documentation",
    "status": "pending",
    "priority": "high",
    "dueDate": "2026-08-15T00:00:00.000Z",
    "createdAt": "2026-08-07T12:34:56.789Z"
  }
}
```

This is unchanged from the Kafka draft, deliberately — the envelope is a contract between producer and consumer and has nothing to say about the transport underneath.

`eventId` is a **ULID** — sortable by time, unlike UUIDv4, which matters for a log. A ULID is 128 bits, so `evt_<ULID>` on the wire and the `UUID` in `outbox.event_id` are the same value in two encodings. Keep them that way: the consumer's idempotency check (§4.6) is a lookup by that id, and it only works if the id survives the round trip.

`traceId` and `spanId` propagate the trace across the async boundary; without them your distributed trace stops dead at the producer and the consumer's work appears as an unrelated orphan trace.

A stream entry is a flat field→value map, so carry the envelope as JSON in one field and hoist the routing fields beside it:

```
XADD taskflow:dev:events:task MAXLEN ~ 100000 *
     eventId   evt_01J8XQZ4K5N6P7R8S9T0V1W2X3
     eventType task.created
     traceId   4bf92f3577b34da6a3ce929d0e0e4736
     payload   {"eventId":"evt_01J8…","eventType":"task.created", … }
```

The duplication buys you `XRANGE` filtering and readable `redis-cli` output without parsing every body — the Streams equivalent of Kafka record headers, which is also where `traceparent` would go on the Kafka path.

Event types: `task.created`, `task.updated`, `task.status_changed`, `task.deleted`, `task.restored`, `attachment.added`, `attachment.removed`, `user.registered`, `user.profile_updated`, `user.deleted`.

### 4.5 The transactional outbox — the core lesson

This is the part that has nothing to do with which transport you picked, and the reason Phase 6 exists.

**The problem.** This code is wrong, and it is what everyone writes first:

```
tx.begin()
tx.insert(task)
tx.commit()
events.publish(taskCreatedEvent)   // ← what if this fails? or the process dies here?
```

Two independent systems, no shared transaction. Four outcomes, two of them bad:

| DB | Transport | Result |
|---|---|---|
| ✅ | ✅ | Correct |
| ❌ | ❌ | Correct (nothing happened) |
| ✅ | ❌ | **Task exists, no event.** Consumers never learn about it. Silent, permanent inconsistency. |
| ❌ | ✅ | **Event exists, no task.** Consumers act on a task that doesn't exist. |

Swapping the order does not help — it just changes which bad case you get. This is the **dual-write problem**, and it has no solution using two systems and one code path. Distributed transactions (2PC/XA) technically solve it and are avoided in practice: they need both systems to support XA, hold locks across a network round-trip, and block indefinitely if the coordinator dies mid-commit. Valkey does not support XA at all, so the question does not even arise here.

**The solution.** Make the event part of the *same database transaction* as the data, then relay it out separately. The table is in `migrations/002_infrastructure.up.sql` and reproduced in §7; note that nothing in it names a transport.

Write path becomes atomic:

```
tx.begin()
tx.insert(task)
tx.insert(outbox_row)     // same transaction — both or neither
tx.commit()               // ← the only durability decision
```

Relay (separate goroutine/task/worker, one per service):

```sql
-- SKIP LOCKED lets N relay instances run concurrently without
-- ever handing the same row to two of them.
WITH claimed AS (
  SELECT id FROM outbox
  WHERE published_at IS NULL AND attempts < 10
  ORDER BY id
  LIMIT 100
  FOR UPDATE SKIP LOCKED
)
SELECT o.* FROM outbox o JOIN claimed c ON o.id = c.id ORDER BY o.id;
```

Then, for each claimed row in id order, `XADD` and mark it published:

```
XADD <stream> MAXLEN ~ 100000 * eventId … payload …
UPDATE outbox SET published_at = NOW() WHERE id = ANY($1)
```

On failure, `attempts = attempts + 1, last_error = $2` and let the next poll retry. **Do not mark `published_at` before the `XADD` returns an id** — that converts a transient outage into permanent, silent data loss, and it is the single easiest way to make every test in this phase pass while being wrong.

`ORDER BY id` in both the claim and the publish is load-bearing. Ordering is the one property a single stream gives you for free (§4.2), and publishing a claimed batch concurrently throws it away for no benefit.

**This gives at-least-once, not exactly-once.** The relay can `XADD` and then crash before marking `published_at`, so the event goes out twice. That is unavoidable, and it is why INF2.5 requires idempotent consumers. "Exactly-once delivery" does not exist in distributed systems; "exactly-once *processing*" is achieved by at-least-once delivery plus idempotency at the consumer. If you take one idea from this whole document, make it that one.

**Two relay implementations, and you should build both:**

1. **Polling relay** (build first). ~80 lines, no extra infrastructure, poll every 200 ms. Costs: poll latency, and a query against your primary database on a timer.
2. **`LISTEN`/`NOTIFY` wake-up** (build second, ~20 more lines). A trigger on `outbox` issues `NOTIFY outbox`, the relay blocks on `LISTEN` and polls immediately on wake, keeping the timer only as a safety net for missed notifications. Near-zero latency, no new infrastructure, and it teaches you why the timer must stay: `NOTIFY` is fire-and-forget, so a relay that is reconnecting misses the wake-up entirely.

If you want the industrial version, that is **CDC via Debezium** — see §4.9, where it belongs, because it drags Kafka Connect in with it.

### 4.6 Consumers, the PEL and metrics

Build at least three, so the events are real and not decoration:

| Consumer | Group | Reads | Does |
|---|---|---|---|
| `notification-consumer` | `taskflow.notifications` | task events | Publishes to Valkey pub/sub → WebSocket fan-out (§3.8) |
| `audit-consumer` | `taskflow.audit` | all streams | Appends to the immutable `audit_log` table |
| `analytics-consumer` | `taskflow.analytics` | task events | Maintains a materialised per-user stats table |
| `attachment-reaper` | `taskflow.reaper` | attachment events | Deletes orphaned objects from storage |

The loop:

```
XREADGROUP GROUP taskflow.audit consumer-7 COUNT 50 BLOCK 5000 STREAMS <stream> >
  → for each entry: process, then XACK <stream> taskflow.audit <id>
```

**`>` means "entries never delivered to this group".** Anything already delivered to you and not yet acknowledged is *not* returned again by `>` — it is in your pending-entries list, and getting it back is a separate, deliberate act (`XREADGROUP … 0` for your own PEL, `XAUTOCLAIM` for someone else's). This trips people up: a consumer that crashes and restarts sees nothing waiting for it and concludes all is well, while its own unfinished work sits in the PEL forever.

**Consumer requirements:**

- **Idempotency.** Before processing, `INSERT INTO processed_events (event_id, consumer_group) VALUES (…) ON CONFLICT DO NOTHING`. Zero rows affected → already done → `XACK` and move on. It must be in the **same transaction** as the side effect or it does nothing: in a separate transaction, a crash between the two replays the effect anyway. `ON CONFLICT DO NOTHING`, never `DO UPDATE` — an updated `processed_at` means you re-ran the work and then rewrote the marker, so the guard recorded the duplicate instead of stopping it.
- **`XACK` after the work is durable, never before.** `XACK` is the offset commit. Acknowledging on receipt is the Streams version of `enable.auto.commit=true`, and it loses messages on exactly the crash you were protecting against.
- **A reclaim sweeper.** Nothing reclaims a dead consumer's pending entries automatically — there is no session timeout and no rebalance. Run this on a timer (every `EVENTS_CLAIM_INTERVAL_MS`):

  ```
  XAUTOCLAIM <stream> <group> <me> <min-idle-ms> <cursor> COUNT 50
  ```

  It returns `[next-cursor, claimed-entries, deleted-ids]`; loop until the cursor comes back `0-0`. Set `min-idle-ms` (60 s here) comfortably above your slowest legitimate processing time, or healthy consumers will steal each other's in-flight work and process it twice — which is survivable, because you are idempotent, but it is pure waste. The third element of the reply is entries that were `XDEL`ed while pending: acknowledge them and stop thinking about them.
- **Unique consumer names.** `EVENTS_CONSUMER_NAME` must differ per process. Two replicas sharing a name share a pending list, and neither can tell which of them died.
- **Bounded batches.** `COUNT` tuned so a batch finishes well inside `min-idle-ms`, for the same reason Kafka wants `max.poll.records` to fit inside `max.poll.interval.ms`.

**Metrics** (Prometheus names kept transport-neutral so the dashboards survive the appendix):

| Metric | Type | Labels |
|---|---|---|
| `events_consumer_lag` | Gauge | `stream`, `group` — from `XINFO GROUPS`' `lag` |
| `events_pending_entries` | Gauge | `stream`, `group` — from `XPENDING` |
| `events_consumed_total` | Counter | `stream`, `group`, `result` |
| `events_processing_duration_seconds` | Histogram | `stream`, `group` |
| `events_reclaimed_total` | Counter | `stream`, `group` — `XAUTOCLAIM` hits |
| `events_dlq_total` | Counter | `stream`, `reason` |
| `outbox_pending_events` | Gauge | — |
| `outbox_relay_lag_seconds` | Gauge | — |
| `outbox_publish_failures_total` | Counter | `error_type` |

**`outbox_pending_events` is your canary.** Steady-state it should hover near zero. A rising trend means the relay is falling behind or Valkey is unreachable — and because the outbox absorbs transport outages (INF2.8), this metric is the *only* signal that anything is wrong. Your users see nothing until the backlog becomes unrecoverable. Alert on it above 1,000, or above a 60 s relay lag.

`events_pending_entries` is the second canary and catches the opposite failure: a PEL that only grows is a consumer that reads and never acknowledges.

### 4.7 Poison messages and the dead-letter stream

A message your consumer cannot process — malformed JSON, a schema it does not know, a bug that throws on one particular row — will be retried forever if you let it, and every event behind it waits.

On Kafka the damage is bounded to one partition. **On Streams it is worse: there are no partitions, so a consumer stuck on one entry stalls every user's events at once.** This is the sharpest edge in the whole section, and the fix is the same as Kafka's:

1. Process. On failure, do not `XACK`.
2. Let it come back via `XAUTOCLAIM`. `XPENDING` reports a delivery count per entry.
3. Once the delivery count exceeds `EVENTS_MAX_DELIVERIES` (3), `XADD` the entry to `…:dlq` with the error, the original entry id and the delivery count, then `XACK` the original and keep moving.

A DLQ is just another stream. It needs no special support, gets the same `MAXLEN ~` treatment, and you read it with `XRANGE` when something goes wrong. Give it a consumer group anyway (`taskflow.dlq-review`) so `XINFO`, `XLEN` and the dashboards work before the first poison message arrives.

Two things people get wrong here. **Do not drop the message instead of DLQing it** — dropping is the only outcome worse than retrying forever, because it destroys the evidence. And **do not DLQ on the first failure**: a transient database blip is not a poison message, and a DLQ full of retryable errors is a DLQ nobody reads.

### 4.8 What Streams does not give you

The honest list. Every one of these is a real Kafka feature with no Streams equivalent, and knowing which of them you need is the actual skill.

- **No partitions, therefore no horizontal scale-out of one stream.** A stream is a single log with a single writer path. Adding consumers to a group splits the *work* but not the *log*: throughput is capped by one Valkey instance and, ultimately, one CPU core, because Valkey executes commands on a single thread. Kafka scales a topic by adding partitions and brokers. TaskFlow's write rate is a few hundred events a second at load-test peak, which is two orders of magnitude below where this hurts — but it is a ceiling, not a slope, and you hit it all at once.
  - The flip side, worth stating plainly because it is genuinely nicer: with one log you get **total ordering for free**, where Kafka only gives you per-partition ordering and makes you buy it with a partition key. §4.9's `test_events_are_keyed_by_user_so_one_user_stays_ordered` exists only because Kafka needs it.
- **No log compaction.** Kafka's `cleanup.policy=compact` keeps the latest value per key forever, which is what makes a topic usable as a snapshot of current state (the `taskflow.user-events` topic in the old draft relied on it). Streams trim by count, oldest-first, full stop. If you want "current state per key" on Streams, that is a Postgres table, not a stream.
- **Memory-bound retention, not disk-bound.** Kafka retains for days on cheap disk and, since 4.0, tiers to object storage for effectively unlimited history. A Valkey stream lives in RAM. `MAXLEN ~ 100000` on the task stream is roughly 50 MB; "keep 7 days of everything" is not on the menu. Replay-from-the-beginning as an operational tool has a much shorter horizon here.
- **No schema registry.** No `BACKWARD` compatibility checking, no producer-side validation, no `evolve-and-deploy-independently` safety net. You get JSON and a version field in the envelope, and the discipline is yours to keep.
- **Weaker durability by default.** This dev instance runs `--appendonly no --save ""`, so a restart loses the stream outright. That is deliberate for a dev cache and unacceptable for a log — turn on AOF (`appendfsync everysec`) for any instance holding streams, accept that `everysec` still means "up to one second of events" on a hard kill, and note that Kafka's `acks=all` with `min.insync.replicas=2` is a genuinely stronger guarantee that Valkey's async replication does not match.
- **No exactly-once transactions across topics.** Kafka's transactional producer can commit a read, a write and an offset atomically. Streams cannot. This matters less than the marketing suggests — the outbox plus idempotent consumers is the pattern most teams end up using anyway, and it is the one this project teaches — but it is a real difference.
- **No ecosystem.** Kafka Connect, Debezium sinks, ksqlDB, Flink connectors, every data vendor's ingest path. If events need to leave your service and land in someone else's system, Kafka is a lingua franca and Valkey Streams is not.

**Reach for Kafka when** any of these is true: more than one team consumes your events; you need retention measured in days or replay measured in millions of events; a single stream's throughput or one core is a real ceiling for you; you need compacted state topics; you need CDC into a warehouse; or a schema registry is a compliance requirement rather than a nicety. **Do not reach for it because** an architecture diagram looks more serious with a broker on it. That was the mistake this section used to make.

### 4.9 Appendix: doing it with Kafka

Optional. Nothing in Phase 6 depends on it, and the conformance suite skips it unless you opt in. Do it once, on a quiet afternoon, because operating the real thing for an hour teaches you things this document cannot.

```bash
docker compose -f docker-compose.infra.yml --profile kafka up -d
pytest -m appendix --kafka-brokers localhost:9092
docker compose -f docker-compose.infra.yml --profile kafka down
```

Then set `EVENTS_BACKEND=kafka` and re-run `-m phase6`. The outbox tests — same-transaction write, backlog accumulates while the transport is down, backlog drains on recovery — pass unchanged, because none of them knows what the transport is. That they need no edits is the entire point of the appendix.

**Broker.** Redpanda 26.2 for local dev: one container, Kafka wire protocol, built-in console and schema registry, ~5 s startup instead of ~30 s, ~500 MB instead of ~1 GB. Apache Kafka 4.2 for the "real thing" comparison — **ZooKeeper is fully gone** (removed in 4.0, March 2025; KRaft is the only mode), tiered storage went GA in 4.0, KIP-848's rebalance protocol is broker-default-on since 4.0 but clients still opt in via `group.protocol=consumer`, and 4.2 (Feb 2026) made share groups ("Queues for Kafka") production-ready. NATS JetStream 2.14 is a legitimate lighter third path if you ever want to compare a third model.

**Topics.**

| Topic | Partitions | Replication | Retention | Cleanup | Key |
|---|---|---|---|---|---|
| `taskflow.task-events` | 6 | 1 (dev) / 3 (prod) | 7d | delete | `user_id` |
| `taskflow.attachment-events` | 3 | 1 / 3 | 7d | delete | `task_id` |
| `taskflow.user-events` | 3 | 1 / 3 | ∞ | compact | `user_id` |
| `taskflow.audit-log` | 6 | 1 / 3 | 90d | delete | `user_id` |
| `taskflow.task-events.dlq` | 1 | 1 / 3 | 30d | delete | original key |

`redpanda-init` creates them, and it too is behind the `kafka` profile.

**Why key by `user_id`, not `task_id`.** Kafka guarantees ordering *within a partition*, and the key picks the partition. Keying by `user_id` puts all of one user's events on one partition, processed strictly in order, so `task.created` can never be processed after `task.updated` for the same task. Key by `task_id` and you get better parallelism but lose cross-task ordering for a user. There is no universally right answer, only a right answer for your consistency requirements — and note that on Streams this decision does not exist, because there is one log and everything is ordered (§4.8).

**Why 6 partitions.** Partition count is your maximum consumer parallelism and is expensive to increase later: it changes the key→partition mapping and breaks ordering for in-flight keys. 6 leaves room to scale to 6 consumers without a rekey.

**Client libraries (verified Aug 2026).**

| Language | Recommended | Version | Notes |
|---|---|---|---|
| Go | `github.com/twmb/franz-go` | v1.21.5 | Pure Go, no cgo, supports Kafka 0.8–4.2 and KIP-848. Now the standard choice over `sarama` and `segmentio/kafka-go`. |
| Rust | `rdkafka` | 0.39.0 | librdkafka binding; the de facto standard. `rskafka` is pure-Rust but less complete. |
| Python | `aiokafka` | 0.14.0 | Native asyncio — the right fit alongside FastAPI. `confluent-kafka` 2.15.0 for librdkafka feature parity. |
| C# | `Confluent.Kafka` | 2.15.0 | The only serious .NET option. |
| TypeScript | `@confluentinc/kafka-javascript` | 1.10.0 | ⚠️ **`kafkajs` is abandoned** — last publish Feb 2023. Do not use it. |

> The KafkaJS situation is worth noticing on its own. It was the default Node Kafka client for years, is still the top search result, and appears in most tutorials. It has had no release in three and a half years. **Checking a dependency's last-publish date before adopting it is a production skill**, and this is a clean example of why. (Five new dependencies to track like this — one per language — is a cost the Streams path simply does not have: you already depend on a Redis client from Phase 4.)

**CDC with Debezium.** The industrial alternative to a polling relay: **Debezium 3.6.1.Final** (Aug 2026) reads the Postgres WAL through `pgoutput` and its built-in Outbox Event Router SMT (`io.debezium.transforms.outbox.EventRouter`) maps outbox rows onto properly-keyed topics. No polling, near-zero latency, no load on your query path — at the cost of running Kafka Connect and a replication slot. Build the simple relay first and then replace it; that is how you find out what Debezium actually buys you. **A warning worth internalising:** an inactive Postgres logical replication slot retains WAL forever and will fill your disk. It is a classic 3am incident. Monitor `pg_replication_slots.confirmed_flush_lsn` lag from day one.

**Schema registry.** Redpanda's built-in registry (port 8081) is Confluent-API-compatible and needs no extra container; **Apicurio Registry 3.3.0** (which joined the CNCF in June 2026) is the vendor-neutral production alternative with the same API surface.

| Format | Size | Evolution | Use when |
|---|---|---|---|
| **Avro** | Compact | Best-in-class | Data pipelines, registry-centric |
| **Protobuf** | Smallest (~20–30% under Avro) | Good | Internal high-throughput, strong codegen |
| **JSON Schema** | 3–5× larger | Adequate | Human-readable, public APIs |

Use JSON Schema here — you are debugging across five languages, and reading a payload with your eyes beats saving bytes. Set compatibility to `BACKWARD` (a new schema can read old data), which is what lets you deploy producers and consumers independently. Then, as an exercise, migrate `taskflow.task-events` to Protobuf and measure the size and throughput difference; the measurement is the point.

**Environment.** `EVENTS_BACKEND=kafka` plus the `KAFKA_*` block in `.env.example`, which is inert with the default `streams` backend.

---

## 5. Object Storage

### 5.1 The MinIO problem

If you follow any tutorial written before 2026, it will tell you to use MinIO. **Don't.** The `minio/minio` GitHub repository was **archived by its owner on 25 April 2026 and is read-only.** This followed the June 2025 removal of the admin console from the Community Edition; development has moved entirely to the commercial AIStor product. The archived source remains AGPLv3 but the README explicitly disclaims support and warns that production use of self-compiled binaries is at your own risk.

This is a good real-world lesson in itself: the most-recommended tool in every tutorial can be unmaintained, and checking a repo's actual status before adopting it takes thirty seconds.

### 5.2 Alternatives

| Option | Licence | Language | Fit |
|---|---|---|---|
| **SeaweedFS** | Apache 2.0 | Go | ✅ **Recommended.** Actively maintained, solid S3 API coverage, single-binary dev mode |
| **Garage** | AGPLv3 | Rust | ✅ Excellent for minimal setups; runs in ~1 GB RAM, no central coordinator |
| **LocalStack (S3)** | varies by tier | Python | Good for tests; check current free-tier limits |
| **RustFS** | Apache 2.0 | Rust | ⚠️ Alpha — watch, don't adopt |
| ~~MinIO CE~~ | AGPLv3 | Go | ❌ Archived April 2026 |

```yaml
seaweedfs:
  image: chrislusf/seaweedfs:4.41
  container_name: taskflow-s3
  command: 'server -dir=/data -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json -master.volumeSizeLimitMB=1024'
  ports:
    - "8333:8333"   # S3 API
    - "9333:9333"   # master UI
  volumes:
    - seaweed_data:/data
    - ./infrastructure/seaweedfs/s3.json:/etc/seaweedfs/s3.json:ro
```

```bash
S3_ENDPOINT=http://seaweedfs:8333
S3_REGION=us-east-1
S3_BUCKET=taskflow-attachments
S3_ACCESS_KEY=taskflow
S3_SECRET_KEY=taskflow-dev-secret
S3_FORCE_PATH_STYLE=true          # required for non-AWS S3
S3_PRESIGN_EXPIRY_SECONDS=900
```

### 5.3 Presigned uploads

The naive attachment flow streams 10 MB through your API process, occupying a request handler and its memory for the duration. Presigned URLs let the client talk to storage directly:

```
1. POST /tasks/:id/attachments/presign
   → API authorises, generates an S3 key, returns a presigned PUT URL (15 min)
2. Client PUTs the file straight to storage. Your API is not involved.
3. POST /tasks/:id/attachments/complete { uploadId, fileName, fileSize, mimeType }
   → API HEADs the object to verify it exists and matches the declared size,
     then inserts the attachments row.
```

The API never touches the bytes. Memory stays flat regardless of file size and concurrency, and your p99 stops being hostage to the slowest client's uplink.

**The failure mode this introduces:** step 2 succeeds, step 3 never happens (client crashes, user closes the tab). You now have an orphaned object nobody knows about. Hence INF3.5 — a reaper that lists objects older than 24h with no matching `attachments` row and deletes them. Every optimisation moves the problem somewhere; noticing where is the skill.

Keep the original multipart endpoint (`POST /tasks/:taskId/attachments`) working too. Implementing both and measuring memory under 50 concurrent 10 MB uploads is one of the more visceral demonstrations in this project.

---

## 6. Updated Docker Compose Topology

```
docker-compose.yml                  # postgres + 5 APIs (existing)
docker-compose.infra.yml            # valkey (+ function/stream init), seaweedfs
                                    #   profile `kafka`: redpanda, console, topic init
docker-compose.observability.yml    # otelcol, prometheus, loki, tempo, pyroscope, grafana
docker-compose.tools.yml            # k6, schemathesis, migration runner
```

```bash
# everything
docker compose \
  -f docker-compose.yml \
  -f docker-compose.infra.yml \
  -f docker-compose.observability.yml up -d

# just one language + its dependencies
docker compose -f docker-compose.yml -f docker-compose.infra.yml up -d postgres valkey go-api

# the optional Kafka appendix (§4.9) — not started by any of the above
docker compose -f docker-compose.infra.yml --profile kafka up -d
```

Splitting the files is not cosmetic: `docker compose up` on all of it is ~15 containers and several GB of RAM, and you will not want that running while you iterate on one service.

---

## 7. Schema Additions

Read `outbox`, `processed_events` and `audit_log` looking for the word "Kafka", or "stream", or "topic". They are not there, and that is deliberate: **the outbox schema is transport-agnostic**. `partition_key` is the closest it comes, and it is simply "which entity's events must stay ordered" — a Kafka record key, a Streams no-op, a NATS subject.

This is why §4 could be rewritten from Kafka to Valkey Streams without touching a single migration, and why the appendix (§4.9) costs one config flag rather than a schema change. When you design a durability boundary, keeping the transport's vocabulary out of the table is what buys you that freedom later.

```sql
-- migrations/002_infrastructure.up.sql

-- Transactional outbox (§4.5)
CREATE TABLE outbox (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id       UUID         NOT NULL UNIQUE,
    aggregate_type VARCHAR(50)  NOT NULL,
    aggregate_id   UUID         NOT NULL,
    event_type     VARCHAR(100) NOT NULL,
    event_version  VARCHAR(10)  NOT NULL DEFAULT '1.0',
    partition_key  VARCHAR(255) NOT NULL,
    payload        JSONB        NOT NULL,
    headers        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    published_at   TIMESTAMPTZ,
    attempts       INT          NOT NULL DEFAULT 0,
    last_error     TEXT
);
CREATE INDEX idx_outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;
CREATE INDEX idx_outbox_aggregate   ON outbox (aggregate_type, aggregate_id);

-- Consumer idempotency (§4.6)
CREATE TABLE processed_events (
    event_id       UUID         NOT NULL,
    consumer_group VARCHAR(100) NOT NULL,
    processed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, consumer_group)
);
CREATE INDEX idx_processed_events_at ON processed_events (processed_at);

-- Immutable audit log (§4.6)
CREATE TABLE audit_log (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     UUID         NOT NULL UNIQUE,
    event_type   VARCHAR(100) NOT NULL,
    actor_id     UUID,
    subject_type VARCHAR(50)  NOT NULL,
    subject_id   UUID         NOT NULL,
    payload      JSONB        NOT NULL,
    trace_id     VARCHAR(32),
    occurred_at  TIMESTAMPTZ  NOT NULL,
    recorded_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_audit_log_subject  ON audit_log (subject_type, subject_id);
CREATE INDEX idx_audit_log_actor    ON audit_log (actor_id, occurred_at DESC);
CREATE INDEX idx_audit_log_occurred ON audit_log (occurred_at DESC);

-- Pending uploads, for orphan reaping (§5.3)
CREATE TABLE pending_uploads (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID         NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    user_id     UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    object_key  VARCHAR(1024) NOT NULL UNIQUE,
    file_name   VARCHAR(255) NOT NULL,
    declared_size BIGINT     NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    CONSTRAINT pending_uploads_size CHECK (declared_size > 0 AND declared_size <= 10485760)
);
CREATE INDEX idx_pending_uploads_stale ON pending_uploads (created_at) WHERE completed_at IS NULL;

-- Cleanup: retain 7 days of processed_events and published outbox rows.
-- Run via pg_cron or an application-level scheduled job.
-- DELETE FROM processed_events WHERE processed_at < NOW() - INTERVAL '7 days';
-- DELETE FROM outbox WHERE published_at < NOW() - INTERVAL '7 days';
```

> Both cleanup queries are load-bearing. An outbox table that is never pruned grows without bound; the partial index keeps *queries* fast, but the table itself will eventually dominate your database size and slow down backups and `VACUUM`. Schedule the deletes from day one.

---

## 8. Verification Checklist

**Cache**
- [ ] Hit ratio > 80% on `GET /tasks` under the Phase 8 load profile
- [ ] Stop Valkey: all endpoints still return 200 (INF1.7), latency rises, no 5xx
- [ ] `PUT /tasks/:id` → immediate `GET` returns fresh data
- [ ] 500 concurrent requests to one cold key produce exactly **one** DB query
- [ ] Cache keys carry the `taskflow:{env}:` prefix

**Rate limiting**
- [ ] 101 requests in 60s → the 101st returns 429 with a correct `Retry-After`
- [ ] With **two** replicas of the same service running, the limit is still 100 total — not 200
- [ ] `/auth/*` limits at 10/min independently of `/tasks/*`
- [ ] All five implementations return identical headers for identical request sequences

**WebSocket fan-out**
- [ ] Two replicas, user connected to A, mutation via B → notification arrives
- [ ] Kill a replica: clients reconnect and resume without duplicate events

**Outbox**
- [ ] Stop Valkey: `POST /tasks` still returns 201, `outbox_pending_events` climbs
- [ ] Restart Valkey: backlog drains on its own, every event reaches the stream
- [ ] Kill the relay mid-publish: the event is republished; the consumer processes it once
- [ ] The outbox row and the task carry the same `created_at` — same transaction, not a later job
- [ ] `SELECT count(*) FROM outbox WHERE published_at IS NULL` → 0 at steady state

**Consumers**
- [ ] `XRANGE` the stream from `0` and re-feed it: no duplicate side effects
- [ ] `XADD` the same `eventId` twice: exactly one `processed_events` row, exactly one `audit_log` row
- [ ] Inject a malformed entry: it lands on `…:dlq`, the stream keeps moving
- [ ] Kill a consumer mid-batch: `XAUTOCLAIM` reclaims its pending entries within `EVENTS_CLAIM_MIN_IDLE_MS`
- [ ] `XPENDING <stream> <group>` → 0 at steady state
- [ ] Consumer lag (`XINFO GROUPS … lag`) returns to 0 within 30s after a 10k-event burst
- [ ] `traceId` from the producing HTTP request is visible on the consumer's span

**Storage**
- [ ] Presigned upload of 10 MB: API RSS does not increase
- [ ] Presigned URL rejected after expiry
- [ ] Orphaned object reaped within 24h
- [ ] Object keys are unguessable

---

## Sources

- [Redis AGPLv3 announcement](https://redis.io/blog/agplv3/) · [Redis licensing](https://redis.io/legal/licenses/)
- [Valkey 9.1 release](https://valkey.io/blog/valkey-9-1-delivers-improvements-in-security-performance-and-more/) · [Linux Foundation — Valkey GA](https://www.linuxfoundation.org/press/linux-foundation-announces-general-availability-of-valkey-8-1)
- [Redis official rate limiting tutorial](https://redis.io/tutorials/howtos/ratelimiting/) · [Redis Functions](https://redis.io/docs/latest/develop/programmability/functions-intro/)
- [Valkey Streams commands](https://valkey.io/commands/#stream) · [Redis Streams intro](https://redis.io/docs/latest/develop/data-types/streams/) · [`XAUTOCLAIM`](https://valkey.io/commands/xautoclaim/) · [`XADD` trimming](https://valkey.io/commands/xadd/)
- [brandur/redis-cell — maintenance status](https://github.com/brandur/redis-cell)
- [Apache Kafka 4.2.0 release announcement](https://kafka.apache.org/blog/2026/02/17/apache-kafka-4.2.0-release-announcement/)
- [Redpanda releases](https://docs.redpanda.com/current/reference/releases/) · [Redpanda docker-compose labs](https://docs.redpanda.com/redpanda-labs/docker-compose/single-broker/)
- [twmb/franz-go](https://github.com/twmb/franz-go) · [Confluent's JavaScript client](https://www.confluent.io/blog/introducing-confluent-kafka-javascript/)
- [Debezium Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html)
- [Apicurio Registry joins CNCF](https://www.apicur.io/blog/2026/06/18/apicurio-registry-joins-cncf)
- [minio/minio — archived repository](https://github.com/minio/minio) · [MinIO ends active development](https://linuxiac.com/minio-ends-active-development/)
