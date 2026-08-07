# TaskFlow — Resilience & Security Specification

How the system behaves when its dependencies misbehave, and how it defends itself.
Companion to `requirements-specification.md`, `observability-specification.md` and `infrastructure-specification.md`.

> **Version note.** Library versions verified **August 2026**.

---

## 1. The Governing Idea

Every dependency you added in the infrastructure spec — Postgres, Valkey, Kafka, object storage — is a new way for your service to fail. A production-grade service is not one that never fails; it is one that **fails in a bounded, predictable, and recoverable way**.

The failure that actually takes systems down is rarely a crash. It is the *cascade*:

```
Database gets 200ms slower
  → request handlers hold connections longer
    → connection pool exhausts
      → requests queue waiting for a connection
        → request latency exceeds the client timeout
          → clients retry, doubling the load
            → thread/task pool exhausts
              → health check (which queries the DB) times out
                → orchestrator kills every replica
                  → total outage from a 200ms blip
```

Every arrow in that chain is a place where a timeout, a bulkhead, a circuit breaker, or a properly-scoped health check would have stopped it. That is what this document specifies.

**The one-sentence version:** *a slow dependency is more dangerous than a dead one*, because a dead one fails fast and a slow one consumes every resource you have while it decides.

---

## 2. Requirements

### RES1: Timeouts

| ID | Requirement | Priority |
|----|-------------|----------|
| RES1.1 | Every outbound call has an explicit timeout. **No unbounded waits anywhere.** | High |
| RES1.2 | Timeouts are budgeted: the sum of downstream timeouts is less than the inbound request timeout | High |
| RES1.3 | Request context/cancellation propagates to every downstream call | High |
| RES1.4 | Server enforces read-header, read-body, write and idle timeouts | High |
| RES1.5 | Database statement timeout is set at the connection level as a backstop | High |
| RES1.6 | Timeout expiry returns 504 with `code: "GATEWAY_TIMEOUT"` | Medium |

### RES2: Retries

| ID | Requirement | Priority |
|----|-------------|----------|
| RES2.1 | Retries apply only to **idempotent** operations and **retryable** errors | High |
| RES2.2 | Retries use exponential backoff with **full jitter** | High |
| RES2.3 | Retry attempts are capped (3) and bounded by the remaining request budget | High |
| RES2.4 | A **retry budget** caps retries at 10% of total requests to prevent retry storms | High |
| RES2.5 | Non-idempotent operations require an `Idempotency-Key` to be retried safely | Medium |
| RES2.6 | Retry attempts are recorded as span events and counted as a metric | Medium |

### RES3: Circuit Breakers & Bulkheads

| ID | Requirement | Priority |
|----|-------------|----------|
| RES3.1 | Each external dependency is wrapped in a circuit breaker | High |
| RES3.2 | Breaker state transitions are logged and exported as a metric | High |
| RES3.3 | An open breaker fails fast — it does not wait for a timeout | High |
| RES3.4 | Concurrency to each dependency is bounded (bulkhead) | Medium |
| RES3.5 | The cache breaker's fallback is the database; the broker breaker's fallback is the outbox | High |

### RES4: Graceful Degradation & Shutdown

| ID | Requirement | Priority |
|----|-------------|----------|
| RES4.1 | Cache unavailable → serve from database, log, continue | High |
| RES4.2 | Broker unavailable → outbox absorbs, writes succeed | High |
| RES4.3 | Object storage unavailable → attachment endpoints 503, task endpoints unaffected | High |
| RES4.4 | Database unavailable → 503 with `Retry-After`; readiness fails; liveness passes | High |
| RES4.5 | On SIGTERM: fail readiness, drain in-flight requests, close connections, exit ≤30s | High |
| RES4.6 | A `preStop` delay ensures load balancers deregister before the process stops accepting | High |

### RES5: Backpressure & Overload

| ID | Requirement | Priority |
|----|-------------|----------|
| RES5.1 | Maximum concurrent in-flight requests is bounded; excess is shed with 503 | High |
| RES5.2 | Request body size is capped (1 MB JSON, 10 MB multipart) before parsing | High |
| RES5.3 | Load shedding prefers rejecting new work over degrading in-flight work | High |
| RES5.4 | Shed responses carry `Retry-After` and are counted as a metric | Medium |

### SEC1: Transport & Headers

| ID | Requirement | Priority |
|----|-------------|----------|
| SEC1.1 | HTTPS only; HSTS with `max-age=31536000; includeSubDomains` | High |
| SEC1.2 | TLS 1.2 minimum, 1.3 preferred; weak ciphers disabled | High |
| SEC1.3 | Security headers per §8.1 on every response | High |
| SEC1.4 | CORS allow-list is explicit; `Access-Control-Allow-Origin: *` is never used with credentials | High |
| SEC1.5 | Server version banners removed from response headers | Medium |

### SEC2: Authentication & Authorisation

| ID | Requirement | Priority |
|----|-------------|----------|
| SEC2.1 | bcrypt cost 12; verified with a constant-time comparison | High |
| SEC2.2 | Login performs a **dummy hash** on unknown emails to prevent user enumeration by timing | High |
| SEC2.3 | JWTs validate `alg`, `iss`, `aud`, `exp`, `nbf`; `alg: none` and algorithm confusion are rejected | High |
| SEC2.4 | Refresh tokens are single-use and **rotate** on every refresh | High |
| SEC2.5 | Refresh-token reuse detection revokes the entire token family | High |
| SEC2.6 | Ownership is enforced in the query (`WHERE user_id = $1`), never by post-fetch comparison | High |
| SEC2.7 | Auth failures return an identical response and timing regardless of cause | High |
| SEC2.8 | Signing keys are rotatable; JWTs carry a `kid` header | Medium |

### SEC3: Input Handling

| ID | Requirement | Priority |
|----|-------------|----------|
| SEC3.1 | All input validated against an explicit schema; unknown fields rejected | High |
| SEC3.2 | All SQL parameterised. **String concatenation into SQL is a build failure.** | High |
| SEC3.3 | Sort/filter fields validated against an allow-list, never interpolated | High |
| SEC3.4 | Uploaded file type verified by **magic bytes**, not by extension or client-supplied MIME | High |
| SEC3.5 | Upload size enforced by the server, not trusted from `Content-Length` | High |
| SEC3.6 | Attachment filenames sanitised; path traversal blocked | High |
| SEC3.7 | JSON depth and array length bounded to prevent parser DoS | Medium |
| SEC3.8 | `avatarUrl` restricted to https and validated against SSRF | Medium |

### SEC4: Secrets & Supply Chain

| ID | Requirement | Priority |
|----|-------------|----------|
| SEC4.1 | No secret is ever committed; CI scans every commit and blocks on findings | High |
| SEC4.2 | Local secrets encrypted at rest with SOPS + age | High |
| SEC4.3 | CI uses OIDC federation for cloud access; no long-lived cloud keys in Actions secrets | High |
| SEC4.4 | Every dependency is scanned for known vulnerabilities on every PR | High |
| SEC4.5 | An SBOM is produced for every container image, in both CycloneDX and SPDX | Medium |
| SEC4.6 | Container images are signed and carry build provenance attestations | Medium |
| SEC4.7 | Third-party GitHub Actions are pinned by **commit SHA**, never by tag | High |
| SEC4.8 | Containers run as a non-root user with a read-only root filesystem | High |

---

## 3. Timeout Budget

The critical property: **each layer's timeout must be strictly shorter than its caller's.** Otherwise the caller gives up first, the downstream work continues orphaned, and you burn resources on results nobody will read.

```
Client                                              30s
└── Load balancer / ingress                         25s
    └── API server request timeout                  20s
        ├── Handler budget                          15s
        │   ├── Valkey GET                          200ms   ← 40× healthy p99
        │   ├── Postgres query                      5s      (statement_timeout)
        │   ├── Postgres pool acquire               2s
        │   ├── Kafka produce (outbox relay only)   10s
        │   └── S3 presign                          2s
        └── Response write                          5s
```

### 3.1 Server timeouts

| Setting | Value | Prevents |
|---|---|---|
| Read header | 5s | Slowloris — a client dribbling headers forever |
| Read body | 30s | Slow-POST attacks |
| Handler | 20s | Runaway handlers |
| Write | 30s | Slow-reading clients holding connections |
| Idle (keep-alive) | 120s | Connection accumulation |
| Max header bytes | 1 MB | Header-bomb DoS |
| Graceful shutdown | 30s | Dropped in-flight requests |

### 3.2 Database timeouts

```sql
-- Connection-level, set on every new connection. The last line of defence:
-- even a bug that forgets an application timeout cannot hang forever.
SET statement_timeout = '5s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '10s';
```

`idle_in_transaction_session_timeout` is the one people forget. A transaction opened and then abandoned (a handler that returned without committing) holds locks and blocks `VACUUM` **indefinitely**. On a busy table this eventually stops all writes. Ten seconds is generous; set it.

Pool configuration:

| Setting | Value | Reasoning |
|---|---|---|
| Max connections | 10/instance | 5 services × 2 replicas × 10 = 100, at Postgres's default `max_connections` |
| Min idle | 2 | Avoid cold-start latency |
| Acquire timeout | 2s | Fail fast rather than queue forever |
| Max lifetime | 30m | Survive DNS changes and failovers |
| Max idle time | 10m | Release unused connections |

> **Bigger pools are usually slower.** Postgres performance peaks at roughly `(2 × cores) + effective_spindle_count` active connections; beyond that, context switching and lock contention make everything worse. When your service is slow and the pool is saturated, the reflex is to raise the pool size — that usually makes it worse. Raise it only after you have confirmed the database itself is idle. This is one of the most reliably counter-intuitive results in backend engineering, and TaskFlow's Phase 9 load test is a good place to demonstrate it to yourself: run the same test at pool sizes 5, 10, 25 and 100 and plot p99.

### 3.3 Timeout propagation

Every language has a mechanism; using it is not optional:

| Language | Mechanism |
|---|---|
| Go | `context.Context` threaded through every function that does I/O |
| Rust | `tokio::time::timeout` + cancellation on drop (futures cancel when dropped — mostly free) |
| Python | `asyncio.timeout()` (3.11+) / `asyncio.wait_for` |
| C# | `CancellationToken` on every async call |
| TypeScript | `AbortSignal.timeout()` + `AbortController` |

**The anti-pattern to hunt for in your own code:** a function that does I/O and does not accept a context/token/signal parameter. It cannot be cancelled, which means a timeout upstream cannot actually stop it. Go and C# make this visible through the type signature; Python and TypeScript let you get away with it, so grep for it deliberately.

---

## 4. Retries

### 4.1 What is retryable

| Condition | Retry? | Why |
|---|---|---|
| Connection refused / reset | ✅ | Transient |
| DNS failure | ✅ | Transient |
| Timeout on a **read** | ✅ | Idempotent |
| Timeout on a **write** | ⚠️ Only with an idempotency key | The write may have succeeded |
| HTTP 429 | ✅ After `Retry-After` | Explicitly instructed |
| HTTP 502/503/504 | ✅ | Transient upstream |
| HTTP 500 | ⚠️ Once | Could be deterministic |
| HTTP 4xx (other) | ❌ | Retrying a 400 gets another 400, forever |
| Postgres `40001` (serialization_failure) | ✅ | Designed to be retried |
| Postgres `40P01` (deadlock_detected) | ✅ | Designed to be retried |
| Postgres `23505` (unique_violation) | ❌ | Deterministic |
| Validation errors | ❌ | Deterministic |

### 4.2 Backoff with full jitter

```
delay = random(0, min(cap, base × 2^attempt))

base = 100ms, cap = 5s, max_attempts = 3
attempt 0 → random(0, 100ms)
attempt 1 → random(0, 200ms)
attempt 2 → random(0, 400ms)
```

**Full jitter, not "exponential backoff plus a bit of jitter."** If 1,000 clients fail simultaneously and all back off by exactly 200 ms, they retry simultaneously 200 ms later — you have converted one thundering herd into a periodic one. Randomising across the *whole* interval spreads them evenly. AWS's analysis of this is the canonical reference and the result is unintuitive enough to be worth reading.

### 4.3 Retry budgets

Retries amplify load exactly when the system can least handle it. Three retries per request means a struggling dependency receives **4× traffic** at its worst moment. This is the mechanism behind most cascading failures.

Cap retries at **10% of total request volume** using a token bucket per dependency: each request adds one token, each retry consumes ten. When the bucket is empty, retries are refused and the original error is returned immediately.

```
retry_budget = TokenBucket(rate: requests_per_sec * 0.1, burst: 10)
if !retry_budget.try_take() { return original_error }
```

Also: **retry at exactly one layer.** If the client retries 3×, the gateway retries 3×, and the service retries 3× against the database, one user action becomes 27 database queries. Retry closest to the failure, and make every layer above it non-retrying.

### 4.4 Idempotency keys

For safe write retries, accept an `Idempotency-Key` header on `POST /tasks` and `POST /auth/register`:

```
1. Client generates a UUID, sends it as Idempotency-Key
2. Server: SET taskflow:{env}:idem:{key} "in_progress" NX EX 86400
3. Not acquired → key exists:
     - value is a stored response → return it verbatim with Idempotency-Replayed: true
     - value is "in_progress"     → 409 CONFLICT, request already being processed
4. Acquired → process → store the serialised response at the key, TTL 24h
```

The `NX` is what makes this correct — it's the same atomic-set-if-absent primitive as the stampede lock, and recognising that both problems have the same shape is the useful bit.

### 4.5 Libraries

| Language | Retry | Circuit breaker | Notes |
|---|---|---|---|
| Go | `failsafe-go` v0.9.6 | `sony/gobreaker` v1.0.0 | `failsafe-go` covers retry + breaker + bulkhead + timeout + hedging in one library; `gobreaker` is stable but has had no release since 2024 |
| Rust | `backon` v1.6.0 | `failsafe` v1.3.0 | Compose as `tower` layers. Prefer `tokio-retry2` v0.9.1 over the stale `tokio-retry` |
| Python | `tenacity` v9.1.4 | `pybreaker` v1.4.1 / `aiobreaker` v1.2.0 | |
| C# | `Polly` v8.7.0 | Polly (same) | Use `Microsoft.Extensions.Http.Resilience` v10.8.0 to wire it into `HttpClient` — the officially recommended path |
| TypeScript | `p-retry` v8.0.0 | `cockatiel` v4.0.0 / `opossum` v10.0.0 | `cockatiel` is the closest TS analogue to Polly |

The C# story is worth noticing when you compare the five: Polly v8's resilience pipelines are more mature and more ergonomic than anything in the other four ecosystems, and .NET ships first-party integration for it. That kind of "the platform already solved this" difference is exactly what a five-language project exists to surface.

---

## 5. Circuit Breakers

### 5.1 States

```
        failures ≥ threshold
CLOSED ─────────────────────────→ OPEN
  ↑                                 │
  │                                 │ after cooldown
  │  successes ≥ threshold          ↓
  └───────────────────────────  HALF_OPEN
                                    │
                     any failure    │
                          └─────────┘ → OPEN
```

- **CLOSED** — normal. Count failures.
- **OPEN** — fail immediately without calling. This is the point: not to detect failure, but to *stop consuming resources* on a call you know will fail. A dead dependency with a 5s timeout costs you 5s of a handler, a pool slot and a thread per request; an open breaker costs microseconds.
- **HALF_OPEN** — let a small number of probes through. Success closes it; failure re-opens.

### 5.2 Configuration

| Dependency | Failure threshold | Window | Cooldown | Half-open probes | Fallback |
|---|---|---|---|---|---|
| Valkey | 50% of ≥20 requests | 10s | 5s | 3 | **Query the database** |
| Postgres | 50% of ≥20 requests | 30s | 10s | 2 | 503 + `Retry-After` |
| Kafka | 50% of ≥10 requests | 30s | 30s | 2 | **Leave in outbox** |
| Object storage | 50% of ≥10 requests | 30s | 15s | 2 | 503 on attachments only |

Threshold on a **ratio with a minimum sample size**, not on an absolute count. "5 consecutive failures" fires spuriously on a low-traffic service and far too late on a high-traffic one. "50% of at least 20 requests in the last 10s" scales correctly with traffic.

**Do not put a circuit breaker on Postgres lightly.** For most of TaskFlow the database is not a degradable dependency — if it's down, the service is down, and an open breaker just changes a 5s failure into a fast failure. That is still worth something (it stops pool exhaustion), but it is not "graceful degradation." Be honest in your design docs about which dependencies have real fallbacks (cache → DB, broker → outbox) and which do not.

### 5.3 Metrics

| Metric | Type | Labels |
|---|---|---|
| `circuit_breaker_state` | Gauge (0=closed,1=half,2=open) | `dependency` |
| `circuit_breaker_transitions_total` | Counter | `dependency`, `from`, `to` |
| `circuit_breaker_rejections_total` | Counter | `dependency` |
| `retry_attempts_total` | Counter | `dependency`, `attempt`, `outcome` |
| `retry_budget_exhausted_total` | Counter | `dependency` |
| `bulkhead_rejections_total` | Counter | `dependency` |
| `load_shed_total` | Counter | `reason` |

---

## 6. Graceful Shutdown

Getting this wrong drops requests on every deploy. With ten deploys a week, that is a permanent low-grade error rate that nobody ever tracks down because it never reproduces locally.

```
SIGTERM received
  ↓
1. Set ready = false             → /health/ready starts returning 503
  ↓
2. Sleep 5s                      ← CRITICAL. Load balancers poll readiness
                                   every 2–10s. Without this delay, traffic is
                                   still arriving when you stop accepting it.
  ↓
3. Stop accepting new connections (close listener)
  ↓
4. Wait for in-flight requests   (max 20s)
  ↓
5. Close WebSockets with code 1001 "going away"  → clients reconnect elsewhere
  ↓
6. Flush the outbox relay's current batch
  ↓
7. Commit consumer offsets, leave the consumer group cleanly
  ↓
8. Flush telemetry (OTel force-flush, max 5s)
  ↓
9. Close DB pool, cache pool, broker producer
  ↓
10. exit(0)
```

**Step 2 is the one everyone omits.** Your process is fast and correct; the load balancer is eventually-consistent. Between "process stops accepting" and "load balancer notices," every request routed to you is a 502 to a real user. Five seconds of doing nothing fixes it.

In Kubernetes, pair it with:

```yaml
lifecycle:
  preStop:
    exec: { command: ["sh", "-c", "sleep 5"] }
terminationGracePeriodSeconds: 45   # must exceed the full sequence above
```

Language mechanics:

| Language | Approach |
|---|---|
| Go | `signal.NotifyContext` → `srv.Shutdown(ctx)` |
| Rust | `axum::serve(...).with_graceful_shutdown(signal)` |
| Python | uvicorn handles SIGTERM; use FastAPI `lifespan` for cleanup |
| C# | `IHostApplicationLifetime.ApplicationStopping` + `HostOptions.ShutdownTimeout` |
| TypeScript | `process.on('SIGTERM')` → `server.close()` + explicitly track and close sockets (Node keeps keep-alive connections open otherwise — `server.closeIdleConnections()`) |

---

## 7. Backpressure & Load Shedding

When demand exceeds capacity you have exactly two options: **queue** (latency grows without bound until everything times out and all the work is wasted) or **shed** (some requests fail fast, the rest are served correctly). Shedding is almost always right — serving 70% of traffic well beats serving 100% of it past the timeout.

```
Concurrency limiter:
  max_in_flight = 200                    ← measure, don't guess
  if in_flight >= max_in_flight:
      return 503 { code: "SERVICE_OVERLOADED", retryAfter: 1 }

Body limits (enforced BEFORE parsing):
  JSON      1 MB
  multipart 10 MB (matches FR4.1)

Queue depth:
  outbox relay backlog > 10,000 → log warn, alert
  Kafka consumer lag > 100,000  → alert
```

**Shed the cheapest thing first.** Rejecting a request before parsing its body costs microseconds; rejecting it after a database query wasted the query. Order your middleware so limits are checked in increasing cost: body-size → concurrency → rate limit → auth → handler.

Two refinements worth trying in Phase 9:

- **Adaptive concurrency** (Netflix's gradient algorithm, Vegas-style): rather than a fixed `max_in_flight`, derive the limit from observed latency. When latency rises above the recent minimum, lower the limit. Self-tunes across hardware.
- **Priority shedding**: shed `GET /tasks` before `POST /auth/login`. A user who cannot list tasks is inconvenienced; a user who cannot log in is locked out.

---

## 8. Security Hardening

### 8.1 Response headers (every response)

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: default-src 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
Cross-Origin-Resource-Policy: same-origin
Cache-Control: no-store            # on all authenticated responses
```

`default-src 'none'` is correct for a JSON API — it serves no HTML, scripts, or styles, so nothing should ever load. Also **remove** `Server`, `X-Powered-By` and `X-AspNet-Version`; version banners are free reconnaissance.

### 8.2 The timing-attack fix in login

The naive implementation leaks which emails are registered:

```
user = db.find_by_email(email)
if user == nil:           return 401     ← returns in ~1ms
if !bcrypt.verify(pw, user.hash): return 401  ← returns in ~250ms
```

An attacker measures response time and enumerates your entire user base. The fix:

```
user = db.find_by_email(email)
if user == nil:
    bcrypt.verify(password, DUMMY_HASH)   // burn the same ~250ms
    return 401 INVALID_CREDENTIALS
if !bcrypt.verify(password, user.hash):
    return 401 INVALID_CREDENTIALS        // identical body, identical code
```

`DUMMY_HASH` is a precomputed cost-12 bcrypt hash of an arbitrary string, generated once at startup. The two paths must return the *same* error code and body too — `USER_NOT_FOUND` vs `INVALID_PASSWORD` leaks the same information without needing a stopwatch.

> This is worth measuring rather than trusting: put a histogram on login duration labelled by outcome, and confirm the distributions overlap.

### 8.3 JWT validation

Validate all of these. Skipping any one is a known CVE class:

```
✅ Signature verifies with the expected key
✅ alg matches the expected algorithm — reject "none"; reject HS256 when RS256 is expected
✅ exp in the future (≤60s clock skew allowance)
✅ nbf in the past
✅ iss == "taskflow"
✅ aud == "taskflow-api"
✅ sub parses as a valid user ID
✅ typ == "access" for access tokens (a refresh token must not work as an access token)
✅ kid resolves to a known key
```

**The algorithm-confusion attack.** If your verification passes the algorithm from the token's own header, an attacker takes your *public* RS256 key (which is public by definition), signs a token with it as HS256, and your library — told by the attacker's header to use HMAC — verifies it with the public key as the shared secret. It validates. Always pin the expected algorithm on the verification call; never read it from the token.

### 8.4 Refresh-token rotation and reuse detection

Rotation: every refresh issues a new refresh token and revokes the old one.

Reuse detection: if a **revoked** refresh token is presented, that token was stolen — either the attacker is using a copy of one the legitimate user already rotated, or vice versa. You cannot tell which, so revoke the entire **family**:

```sql
ALTER TABLE refresh_tokens
  ADD COLUMN family_id  UUID NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN parent_id  UUID REFERENCES refresh_tokens(id),
  ADD COLUMN used_at    TIMESTAMPTZ;

CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id)
  WHERE revoked_at IS NULL;
```

```
On refresh:
  token = lookup(sha256(presented))
  if token.revoked_at != null OR token.used_at != null:
      # REUSE DETECTED
      UPDATE refresh_tokens SET revoked_at = NOW() WHERE family_id = token.family_id
      log.warn("refresh token reuse detected", family_id, user_id)
      increment(security_token_reuse_detected_total)
      return 401 UNAUTHORIZED
  mark token used, issue child with the same family_id
```

The user is forced to log in again — mildly annoying, and exactly the right outcome when a token has leaked. This design is what OAuth 2.1 mandates for public clients, and implementing it here means you'll recognise it when you meet it.

### 8.5 Ownership enforcement

**Correct** — the filter is in the query:

```sql
SELECT * FROM tasks WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL;
```

**Wrong** — fetch then compare:

```
task = db.get(id)
if task.user_id != current_user.id: return 403
```

The wrong version leaks existence through the 403-vs-404 distinction (an attacker enumerating IDs learns which exist), and it is one forgotten check away from full IDOR. Return **404, not 403**, for a resource the user does not own — "not found" is the truthful answer from that user's perspective.

Cover this with a test that runs against all five implementations: create a task as user A, attempt every operation on it as user B, assert 404 every time.

### 8.6 File upload validation

```
1. Content-Length ≤ 10 MB                    (reject early)
2. Enforce the limit while streaming          (Content-Length is client-supplied and can lie)
3. Read the first 512 bytes, detect type by MAGIC BYTES
4. Allow-list the detected type — never the client's Content-Type, never the extension
5. Sanitise the filename: strip path separators, null bytes, control chars;
   reject "..", leading "-", reserved Windows names (CON, PRN, AUX, NUL, COM1…)
6. Store under a generated key: attachments/{task_id}/{uuid}/{sanitised_name}
7. Serve downloads with:
     Content-Disposition: attachment; filename="..."
     Content-Type: application/octet-stream    (never the detected type)
     X-Content-Type-Options: nosniff
```

Allowed types: `image/jpeg`, `image/png`, `image/gif`, `image/webp`, `application/pdf`, `text/plain`, `text/csv`, `application/zip`, and the Office/OpenDocument MIME types.

Step 7 matters more than it looks: serving user-uploaded content with its real `Content-Type` from your own origin is stored XSS. An uploaded `.html` or `.svg` served as `text/html`/`image/svg+xml` executes JavaScript in your origin. Force `application/octet-stream` + `nosniff`, and if you ever serve attachments inline, do it from a separate origin.

### 8.7 SSRF on `avatarUrl`

`PUT /auth/profile` accepts a URL. If anything server-side ever fetches it (thumbnailing, validation, caching), you have handed attackers a request forger inside your network:

```
❌ http://169.254.169.254/latest/meta-data/    cloud instance metadata → credentials
❌ http://localhost:9090/                       your own Prometheus
❌ http://postgres:5432/                        internal service scan
❌ file:///etc/passwd
❌ gopher://…                                   protocol smuggling
```

Rules: scheme must be `https`; resolve DNS and reject private/loopback/link-local/multicast ranges (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`, `::1`, `fc00::/7`); re-check the IP **after** redirects (DNS rebinding); cap redirects at 3; timeout 5s; cap response size.

Simplest correct answer for TaskFlow: **store the URL, never fetch it.** Not fetching is a complete defence, and recognising when the safest design is to not implement the feature is a real engineering judgement.

### 8.8 Container hardening

```dockerfile
# Non-root, minimal, no shell
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

```yaml
# compose / k8s
security_opt: ["no-new-privileges:true"]
read_only: true
tmpfs: ["/tmp:size=64M"]
cap_drop: ["ALL"]
user: "65532:65532"
```

Distroless has no shell, no package manager, no `curl`. An attacker with RCE gets a process and nothing to pivot with. It also drops image size by 80–95%, which speeds every pull in CI.

Per-language base images:

| Language | Runtime base | Approx size |
|---|---|---|
| Go | `gcr.io/distroless/static-debian13:nonroot` | ~15 MB |
| Rust | `gcr.io/distroless/cc-debian13:nonroot` | ~25 MB |
| Python | `gcr.io/distroless/python3-debian13:nonroot` | ~55 MB |
| C# | `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra` | ~110 MB |
| TypeScript | `gcr.io/distroless/nodejs24-debian12:nonroot` | ~135 MB |

Note the read-only root filesystem requirement: it will break any code that writes to disk (temp files during upload handling, some logging libraries). Finding out *what* your service writes and why is a useful exercise on its own.

---

## 9. Secrets Management

### 9.1 By environment

| Environment | Approach |
|---|---|
| **Local dev** | `.env` (gitignored) + `.env.example` (committed, dummy values only) |
| **Shared dev** | **SOPS + age** — encrypted files committed to git, decrypted with per-developer keys |
| **CI** | GitHub Actions encrypted secrets; **OIDC federation** for cloud access — no static cloud keys |
| **Production** | Cloud secrets manager (AWS/GCP/Azure) synced via External Secrets Operator, or OpenBao |

### 9.2 SOPS + age

```bash
age-keygen -o ~/.config/sops/age/keys.txt
# .sops.yaml
creation_rules:
  - path_regex: secrets/.*\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

sops -e -i secrets/dev.enc.yaml    # encrypt in place
sops -d secrets/dev.enc.yaml       # decrypt to stdout
```

Values are encrypted; **keys stay in plaintext**, so `git diff` shows you *which* secret changed without revealing it. That property is why SOPS beats blanket file encryption for a git-based workflow.

### 9.3 Vault / OpenBao

HashiCorp Vault moved to BUSL in 2023, prompting the Linux Foundation **OpenBao** fork; IBM completed its HashiCorp acquisition in early 2025. OpenBao has real production adoption (NVIDIA among them) and is a viable drop-in for teams wanting a fully-OSS path.

For a project this size, running a full Vault/OpenBao is over-engineering — SOPS + age plus a cloud secrets manager covers the need with a fraction of the operational surface. Stand one up in Phase 10 **if** you specifically want to learn dynamic secrets (short-lived per-request database credentials), which is the one capability the simpler tools genuinely cannot provide.

### 9.4 Secret scanning

```yaml
- uses: gitleaks/gitleaks-action@<sha>     # every commit, blocks the PR
- uses: trufflesecurity/trufflehog@<sha>   # verified-secrets mode
```

Enable GitHub **push protection** so secrets are blocked at push time rather than caught after they are already in history. Once a secret reaches a public repo, assume it is compromised — rewriting history does not un-leak it, only rotation does.

---

## 10. Supply Chain

### 10.1 Pipeline

```
1. Dependency scan       Trivy v0.73.0 / Grype v0.116.1 → fail on CRITICAL/HIGH
2. Static analysis       gosec, cargo-audit + clippy, bandit + ruff,
                         dotnet security analyzers, eslint-plugin-security
3. Build container       reproducible, pinned base digests
4. Image scan            Trivy → fail on CRITICAL
5. SBOM                  Syft v1.50.0 → CycloneDX + SPDX
6. Sign                  Cosign v2.6.5 (keyless, OIDC identity)
7. Attest provenance     actions/attest-build-provenance → SLSA Build L2
8. Push                  only if 1–7 pass
```

```bash
syft taskflow-go:${SHA} -o cyclonedx-json=sbom.cdx.json -o spdx-json=sbom.spdx.json
cosign sign --yes ghcr.io/you/taskflow-go@${DIGEST}
cosign attest --yes --predicate sbom.cdx.json --type cyclonedx ghcr.io/you/taskflow-go@${DIGEST}
```

Generate **both** SBOM formats — it is one extra flag. SPDX (ISO/IEC 5962) dominates regulatory contexts; CycloneDX dominates security tooling (Trivy, Grype, Dependency-Track all consume it natively). Both are accepted for CRA compliance.

### 10.2 SLSA levels

| Level | Requirement | How |
|---|---|---|
| L1 | Provenance exists | `actions/attest-build-provenance` |
| **L2** | Signed provenance from a hosted build service | GitHub artifact attestations — **achieved out of the box** |
| L3 | Non-falsifiable provenance, isolated build | Build inside a non-customisable reusable workflow |

Target **L2**, which you get almost for free, and reach L3 by moving the build into a locked-down reusable workflow. Verify with `gh attestation verify` or `cosign verify-attestation`.

### 10.3 Regulatory context

The **EU Cyber Resilience Act** has two dates that matter:

- **11 September 2026** — vulnerability and incident reporting obligations begin. 24h early warning, 72h detailed report, 14-day final report to ENISA/CSIRTs for actively-exploited vulnerabilities. Applies retroactively to products already on the market.
- **11 December 2027** — full compliance: SBOM in technical documentation (SPDX or CycloneDX, no single mandated format), security-by-design, 10-year documentation retention, CE marking. Penalties up to €15M or 2.5% of global turnover.

A learning project is not "placed on the market" and is not in scope. The reason to build this pipeline anyway is that the practices it enforces — SBOM per build, scanning gate, signed provenance — are becoming the professional baseline, and the September 2026 date means teams are actively implementing them right now.

### 10.4 GitHub Actions hardening

In March 2025 the widely-used `tj-actions/changed-files` action was compromised: an attacker force-pushed a malicious commit over existing tags, including major-version tags, and CI secrets were dumped into build logs across an estimated 23,000+ repositories.

The lesson is structural, not incidental: **`@v4` is a mutable pointer.** Whoever controls the repository can move it, retroactively, in every workflow that uses it.

```yaml
# ❌ mutable — the attack vector
- uses: tj-actions/changed-files@v44

# ✅ immutable — a SHA cannot be rewritten to point elsewhere
- uses: tj-actions/changed-files@2f7c5bfce28377bc069a65ba478de0a74aa0ca32 # v44.5.7
```

Plus:

```yaml
permissions: read-all              # workflow-level default
jobs:
  publish:
    permissions:                   # widen only where needed
      contents: read
      id-token: write              # OIDC, so no static cloud credentials
      packages: write
```

Never use `pull_request_target` with an untrusted checkout. Use Dependabot or Renovate (both understand SHA pins and will bump them with the version in a comment) so pinning doesn't mean going stale.

---

## 11. Threat Model (STRIDE)

| Threat | Vector | Mitigation |
|---|---|---|
| **Spoofing** | Forged JWT | Full validation §8.3; pinned algorithm; `kid` rotation |
| | Credential stuffing | Rate limit `/auth/*` 10/min per IP; monitor `taskflow_logins_total{outcome="invalid_credentials"}` |
| **Tampering** | SQL injection | Parameterised queries (SEC3.2); allow-listed sort fields |
| | Mass assignment | Explicit DTOs; reject unknown fields (SEC3.1) |
| | Supply chain | SHA-pinned actions; scanning; signed images |
| **Repudiation** | "I didn't do that" | Immutable `audit_log` fed from the event stream |
| **Information disclosure** | User enumeration | Dummy hash §8.2; identical errors |
| | IDOR | Ownership in the query; 404 not 403 (§8.5) |
| | Secrets in logs | Logger-level redaction; collector-level strip; CI scanning |
| | Stack traces to clients | Generic 500 body; details to logs only |
| | SSRF | §8.7 — or simply don't fetch |
| **Denial of service** | Request flood | Rate limiting; concurrency limits; load shedding |
| | Large body | 1 MB / 10 MB caps enforced before parsing |
| | Slowloris | Read-header timeout 5s |
| | Cache stampede | `NX` lock + TTL jitter |
| | Retry storm | Retry budgets §4.3 |
| | Zip bomb / deep JSON | Depth and size limits (SEC3.7) |
| | bcrypt CPU exhaustion | Rate limit `/auth/*`; bcrypt is deliberately expensive — that cuts both ways |
| **Elevation of privilege** | Refresh token theft | Rotation + family revocation §8.4 |
| | Container escape | Non-root, read-only rootfs, dropped caps, distroless |
| | Path traversal in uploads | Filename sanitisation; generated keys |

---

## 12. Chaos Exercises

Read about resilience, then break things and watch. Run these against a service under steady load (a k6 constant-arrival-rate run) with Grafana open — the dashboards are how you *see* whether the mitigation worked.

| # | Experiment | Command | Expected |
|---|---|---|---|
| 1 | Cache down | `docker compose stop valkey` | 200s continue; latency ↑; breaker opens; zero 5xx |
| 2 | Cache slow | `tc qdisc add dev eth0 root netem delay 500ms` | 200ms timeout trips; falls through to DB |
| 3 | DB down | `docker compose stop postgres` | 503 + `Retry-After`; readiness fails; **liveness passes** |
| 4 | DB slow | `netem delay 2s` on postgres | Pool saturates; `db_client_connection_pending_requests` rises before latency does |
| 5 | Broker down | `docker compose stop redpanda` | Writes succeed; `outbox_pending_events` climbs; drains on restart |
| 6 | Collector down | `docker compose stop otel-collector` | **No user-visible impact at all** — verify this |
| 7 | Storage down | `docker compose stop seaweedfs` | Attachments 503; tasks unaffected |
| 8 | Kill a replica mid-request | `docker kill --signal=SIGTERM` | Zero dropped requests; WebSockets get 1001 |
| 9 | Traffic 10× | k6 ramp to 10× capacity | Load shedding engages; p99 for *served* requests stays bounded |
| 10 | Poison message | Produce malformed JSON to the topic | DLQ receives it; partition keeps moving |
| 11 | Clock skew | Skew one container by 5 min | JWT skew tolerance holds; rate limiter behaviour documented |
| 12 | Connection exhaustion | Open 500 idle connections | Idle timeout reclaims them; service stays responsive |

**Experiment 3 is the acid test for the whole document.** If liveness fails when the database is down, your orchestrator will kill every healthy replica during a recoverable database blip, and you will have built the exact cascade this specification exists to prevent.

---

## 13. Verification Checklist

**Timeouts**
- [ ] Every outbound call site has an explicit timeout (audit by grep, per language)
- [ ] Sum of downstream timeouts < inbound timeout
- [ ] `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` set on every connection
- [ ] Cancelling a request cancels the in-flight DB query (verify in `pg_stat_activity`)

**Retries**
- [ ] 4xx is never retried
- [ ] Backoff uses full jitter — log the delays and confirm they're spread, not clustered
- [ ] Retry budget caps amplification at 10%
- [ ] `Idempotency-Key` replay returns the stored response, not a duplicate task

**Breakers**
- [ ] Breaker opens under induced failure and closes on recovery
- [ ] Open breaker returns in < 1 ms (verify — this is the entire point)
- [ ] Cache breaker falls back to DB with no user-visible error

**Shutdown**
- [ ] SIGTERM under load drops **zero** requests
- [ ] Readiness flips to 503 ≥5s before the listener closes
- [ ] Telemetry from the final requests reaches the collector
- [ ] Consumer offsets committed; group left cleanly

**Security**
- [ ] Login timing for unknown-email vs wrong-password overlaps (measure it)
- [ ] `alg: none` token rejected
- [ ] RS256 public key used as an HS256 secret is rejected
- [ ] Reusing a rotated refresh token revokes the whole family
- [ ] User B gets 404 (not 403) on every operation against user A's task
- [ ] `.html` upload renamed to `.png` is rejected by magic-byte check
- [ ] `../../etc/passwd` as a filename is rejected
- [ ] No stack trace or SQL text in any client-facing response
- [ ] Container runs as non-root with a read-only rootfs
- [ ] All third-party Actions pinned by SHA
- [ ] Trivy/Grype clean of CRITICAL on the final images
- [ ] SBOM generated and attached; image signature verifies

---

## Sources

- [AWS Architecture Blog — Exponential backoff and jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [Polly v8 resilience pipelines](https://www.pollydocs.org/) · [Microsoft.Extensions.Http.Resilience](https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience)
- [failsafe-go](https://failsafe-go.dev/) · [cockatiel](https://github.com/connor4312/cockatiel)
- [tj-actions/changed-files compromise — GHSA-mrrh-fwg8-r2c3](https://github.com/advisories/GHSA-mrrh-fwg8-r2c3) · [Cycode analysis](https://cycode.com/blog/github-action-tj-actions-changed-files-supply-chain-attack-the-complete-guide/)
- [GitHub Actions — secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub artifact attestations & SLSA L3](https://github.blog/enterprise-software/devsecops/enhance-build-security-and-reach-slsa-level-3-with-github-artifact-attestations/)
- [EU Cyber Resilience Act — engineering overview](https://www.docker.com/blog/eu-cyber-resilience-act-overview/)
- [OpenBao](https://openbao.org/) · [NVIDIA adopts OpenBao](https://www.techtarget.com/searchitoperations/news/366644831/Nvidia-adopts-OpenBao-open-source-fork-of-HashiCorps-Vault)
- [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
