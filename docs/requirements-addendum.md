# TaskFlow — Requirements Addendum

Extends `requirements-specification.md` with the production-engineering scope added in this document set.
Read alongside the original; nothing here removes an existing requirement.

---

## 1. Amendments to the Original Specification

### 1.1 Replaced

| Original | Status | Replaced by |
|---|---|---|
| NFR12 — Structured JSON logging with levels | **Superseded** | OBS2.1–2.7 (`observability-specification.md`) |
| NFR13 — Request logged with correlation ID | **Superseded** | OBS2.2, OBS2.4 — trace-based correlation replaces bare request IDs |
| NFR14 — Health check returns DB and service status | **Superseded** | OBS5.1–5.5 — split into liveness / readiness / startup |

> NFR14 is the important one. A single health endpoint that checks the database is a production hazard, not a feature: a recoverable database blip fails liveness on every replica simultaneously and the orchestrator kills them all. See §2 of the observability spec.

### 1.2 Amended

| Original | Amendment |
|---|---|
| FR5.1 — Rate limiting 100 req/min per user | Must be enforced in **shared state** (Valkey), not per-process. In-process counters multiply the effective limit by replica count. See INF1.3–1.4. |
| FR3.1–3.2 — Real-time notifications via WebSocket/SSE | Must fan out via pub/sub so any replica can deliver to any connection. See INF1.6. |
| FR4.1 — File attachments max 10 MB | Presigned-URL upload path added alongside multipart. See INF3.2. |
| NFR1 — p95 < 200 ms | Must be measured with an **open-loop** load generator. The existing `hey`-based benchmark script is closed-loop and produces invalid tail latencies. See TST3.1 and §6.1 of the CI spec. |
| NFR7 — SQL injection prevented | Extended: sort/filter fields must be allow-listed, not interpolated. See SEC3.3. |
| C1 — PostgreSQL | Version pinned to **PostgreSQL 17**; `pg_stat_statements` required. |
| C3 — Comprehensive test suites | Extended: a single language-neutral conformance suite verifies all five, in addition to per-language tests. See TST2. |
| C5 — Identical response formats | Now **enforced** by the differential conformance test (§5.4 of the CI spec) rather than asserted in prose. |
| Response envelope `meta` object | **Additive change**: `meta` gains a `traceId` field (32 lowercase hex, W3C format) alongside the existing `requestId`. `requestId` keeps its `req_` prefix and remains the human-quotable support identifier; `traceId` is the key into Tempo. Both are required on every response. See OBS4.7. |

### 1.3 Moved out of scope

| Item | Reason |
|---|---|
| ~~MinIO for object storage~~ | Repository archived by its owner, 25 April 2026. Use SeaweedFS or Garage. |
| ~~`hey` for benchmarking~~ | Closed-loop only; invalidates p95/p99 under load. Use k6 with arrival-rate executors. |
| ~~`kafkajs` for the TypeScript Kafka client~~ | Last published February 2023; unmaintained. Use `@confluentinc/kafka-javascript`. |
| ~~Per-ORM migrations (5 tools)~~ | Five ORMs generating migrations against one schema conflict. One plain-SQL tool owns the schema. |

---

## 2. New Functional Requirements

### FR6: Caching

| ID | Requirement | Priority |
|----|-------------|----------|
| FR6.1 | Task list and detail responses are cached with a 60s/300s TTL | High |
| FR6.2 | Writes invalidate the owning user's cached entries | High |
| FR6.3 | Cache unavailability degrades to the database without user-visible error | High |
| FR6.4 | Concurrent misses on the same key produce exactly one origin query | Medium |

### FR7: Event Publication

| ID | Requirement | Priority |
|----|-------------|----------|
| FR7.1 | Every task and attachment mutation publishes a domain event | Medium |
| FR7.2 | Events are written to an outbox in the same transaction as the data | High |
| FR7.3 | Events carry the originating `trace_id` | Medium |
| FR7.4 | An immutable audit log is derived from the event stream | Medium |
| FR7.5 | Broker unavailability does not fail the write path | High |

### FR8: Idempotency

| ID | Requirement | Priority |
|----|-------------|----------|
| FR8.1 | `POST /tasks` and `POST /auth/register` accept an `Idempotency-Key` header | Medium |
| FR8.2 | Replaying a key within 24h returns the original response with `Idempotency-Replayed: true` | Medium |
| FR8.3 | A key currently in flight returns 409 `CONFLICT` | Medium |

### FR9: Presigned Uploads

| ID | Requirement | Priority |
|----|-------------|----------|
| FR9.1 | `POST /tasks/:id/attachments/presign` returns a presigned PUT URL (15 min) | Medium |
| FR9.2 | `POST /tasks/:id/attachments/complete` verifies the object and creates the row | Medium |
| FR9.3 | Downloads are served via presigned GET URLs | Medium |
| FR9.4 | Orphaned objects are reaped after 24h | Low |

---

## 3. New Non-Functional Requirements

### Observability
See `observability-specification.md` — OBS1 through OBS7.

### Resilience
See `resilience-and-security-specification.md` — RES1 through RES5.

### Security
See `resilience-and-security-specification.md` — SEC1 through SEC4.

### Infrastructure
See `infrastructure-specification.md` — INF1 through INF3.

### Testing & Delivery
See `cicd-and-testing-specification.md` — TST1 through TST3, CD1.

### Additional performance targets

| ID | Requirement |
|----|-------------|
| NFR15 | Cache hit ratio > 80% on list endpoints under the steady load profile |
| NFR16 | Outbox relay lag < 1s at p99 under steady load |
| NFR17 | Kafka consumer lag returns to zero within 30s of a 10k-event burst |
| NFR18 | Graceful shutdown completes within 30s and drops zero in-flight requests |
| NFR19 | Cold start (process launch → first successful request) recorded per implementation |
| NFR20 | Steady-state RSS recorded per implementation at 500 RPS |
| NFR21 | 5,000 concurrent WebSocket connections sustained with stable memory |
| NFR22 | p95 < 200 ms maintained at 10M tasks |

---

## 4. New Technical Constraints

| ID | Constraint |
|----|------------|
| C7 | A single language-neutral migration tool owns the schema; no ORM generates migrations |
| C8 | All implementations export telemetry via OTLP to one collector endpoint |
| C9 | Histogram bucket boundaries are identical across all five implementations |
| C10 | Containers run as non-root with a read-only root filesystem |
| C11 | All third-party GitHub Actions are pinned by commit SHA |
| C12 | `docs/openapi.yaml` is the normative contract; no implementation defines it |
| C13 | Load testing uses an open-loop (constant-arrival-rate) model |
| C14 | Valkey 9 (or Redis 8 under AGPLv3) — not RSALv2/SSPLv1 builds |

---

## 5. Updated Success Criteria

The project is successful when:

1. All five implementations pass the same **conformance suite** — Schemathesis with `--checks all`, plus the behavioural and differential tests.
2. The differential test reports **zero response-shape divergence** across all five.
3. All five satisfy the observability verification checklist, including metric → trace → log → profile click-through.
4. Chaos experiments 1–12 pass on all five: stopping any single dependency produces the specified degradation, never a cascade.
5. Load-test results are published with **methodology stated in full**, using an open-loop generator, three runs, and recorded variance.
6. A 1-hour soak shows flat memory and connection counts for all five.
7. CI runs lint, test, conformance, security scan, SBOM and signing on every change, with all actions SHA-pinned.
8. A rolling deployment under load drops zero requests, and stopping the database leaves pods Running but out of service.
9. Each implementation is idiomatic for its language — not five transliterations of one design.
10. The write-up documents, per language: what was easy, what was hard, what surprised you, and what you would do differently.

---

## 6. Document Map

```
docs/
├── requirements-specification.md          # original — FR1–5, NFR1–14, C1–6
├── api-specification.md                   # original — endpoints, envelope, errors
├── database-schema.md                     # original — tables, indexes, migration 001
│
├── requirements-addendum.md               # ← this document
├── observability-specification.md         # OBS1–7   — telemetry contract
├── infrastructure-specification.md        # INF1–3   — cache, rate limiting, Valkey
│                                          #            Streams, object storage; Kafka
│                                          #            as an appendix
├── resilience-and-security-specification.md  # RES1–5, SEC1–4
├── cicd-and-testing-specification.md      # TST1–3, CD1 — testing and delivery
├── project-structure-v2.md                # monorepo layout and compose topology,
│                                          #   generated from the tree as it is
├── learning-roadmap.md                    # phases 0–11; 0 ships built, you build 1–11
│
└── openapi.yaml                           # THE NORMATIVE CONTRACT — ships with the
                                           #   repo; the conformance suite reads it
```

**Reading order for someone new to the project:** requirements-specification → api-specification → this addendum → learning-roadmap. The four specification documents are references, consumed phase by phase rather than read front to back.
