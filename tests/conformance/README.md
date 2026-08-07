# TaskFlow conformance & E2E suite

One test suite, five implementations, one contract: `docs/openapi.yaml`.

Nothing in here imports from any implementation. The suite speaks HTTP (plus a
little SQL, Valkey and WebSocket) and does not know or care what language
is answering. That is what makes it usable as the project's yardstick: **it
tells you whether you have finished a given phase in a given language.**

---

## Quick start

```bash
pip install -r tests/conformance/requirements.txt

make up                                # or: docker compose up -d

scripts/check-phase.sh 0                # does the skeleton still stand up? (all five)
scripts/check-phase.sh 1 go             # is Go's core API finished?
scripts/progress.sh                     # the whole-project dashboard
```

`check-phase.sh` exits `0` when the phase passes and non-zero when it does not,
so it drops straight into CI or a git hook.

---

## The loop this is built for

1. Pick a phase and a language.
2. `scripts/check-phase.sh 1 rust` → a wall of **NOT IMPLEMENTED**.
3. Build something.
4. Run it again → fewer.
5. Green. Move on.

The suite is designed so step 2 is *informative* red rather than *confusing*
red. Before you start a phase, every one of its tests should say "you have not
built this yet", not throw an assertion diff at you.

---

## Running it directly with pytest

```bash
pytest tests/ -m phase1 --impl go          # one phase, one language
pytest tests/ -m phase1                    # one phase, all five
pytest tests/ -m "phase1 or phase2"        # several phases
pytest tests/ -m "phase4 and not slow"     # skip the rate-limit soak
pytest tests/ --impl go,rust               # a subset of implementations
pytest tests/ -m phase1 -n auto            # parallel; every test is hermetic
pytest tests/ -k pagination --impl python  # by name
```

### Options

| Option | Default | Purpose |
|---|---|---|
| `--impl` | `all` | `go\|rust\|python\|csharp\|typescript\|all`, or a comma-separated list |
| `--base-url` | — | Ad-hoc target: `--base-url http://staging:8080`, or `--base-url go=http://…`. Repeatable |
| `--phase-report` | `reports/phase-status.json` | Where the machine-readable status is written |
| `--no-phase-report` | off | Suppress the summary and the JSON file |
| `--prometheus-url` | `http://localhost:9090` | Phase 2 metric assertions |
| `--postgres-dsn` | `postgresql://postgres:password@localhost:5432/taskflow_dev` | Phases 0, 3, 6 |
| `--valkey-url` | `redis://localhost:6379/0` | Phases 4 and 6 |
| `--events-stream` | `taskflow:dev:events:task` | Phase 6. Discovered automatically if `ENV` is not `dev` |
| `--events-group` | `taskflow.notifications` | Phase 6 consumer group |
| `--kafka-brokers` | — (unset) | **Optional Kafka appendix only** (`-m appendix`). Unset means the appendix skips |

Every option also reads an environment variable (`TASKFLOW_IMPL`,
`TASKFLOW_POSTGRES_DSN`, …), which is what CI uses.

### Ports

| Implementation | Port |
|---|---|
| go | 8001 |
| rust | 8002 |
| python | 8003 |
| csharp | 8004 |
| typescript | 8005 |

---

## Reading the report

At the end of every run:

```
  PHASE 1 — Core API
  ────────────────────────────────────────────────
  go           ██████████████████████  48/48  PASS
  rust         ███████████████░░░░░░░  33/48  15 failing
  python       ████░░░░░░░░░░░░░░░░░░   9/48  39 not implemented
  csharp       ░░░░░░░░░░░░░░░░░░░░░░   0/48  not reachable
  typescript   ██████████████████████  48/48  PASS
```

Four outcomes, and the difference between them is the point:

| Outcome | Marker in the run | What it means | What to do |
|---|---|---|---|
| **PASS** | `.` | The phase is complete for this language | Next phase |
| **failing** | `F` | Implemented, but behaves differently from the contract | Read the assertion — it quotes the exchange |
| **not implemented** | `N` | The endpoint answered `501 NOT_IMPLEMENTED` | Build it. This is the expected state before you start |
| **not reachable** | `R` | Nothing is listening on the port | `docker compose up -d <lang>-api` |

`not implemented` still counts as a failure and still turns the run red — a
phase you have not built is not a phase you have finished. It is reported
separately so that "I have not written this" never looks like "I have written
this and it is broken".

Every failure message names the language, states the rule in the contract, and
prints the request and response that produced it:

```
go: reading another user's task returned 403. A 403 confirms the resource
exists, which turns the ID space into an enumeration oracle. The contract is 404.
  → GET http://localhost:8001/api/v1/tasks/tsk_9fA2
    headers: {"Accept": "application/json", "Authorization": "Bearer eyJhbGciOi…"}
  ← 403 (12 ms)
    body: { "success": false, "error": { "code": "FORBIDDEN", … } }
```

### The dashboard

`reports/phase-status.json` is **merged**, not overwritten. Checking phase 1 for
Go today and phase 2 for Rust tomorrow leaves both on the board:

```bash
scripts/progress.sh              # render it
scripts/progress.sh --refresh    # re-measure everything first (fast tests only)
scripts/progress.sh --json       # the raw document
```

---

## Layout

```
tests/
├── pytest.ini                        markers, --strict-markers, timeouts
├── conftest.py                       --impl, fixtures, 501 handling, reporting
├── conformance/
│   ├── client.py                     the HTTP wrapper; records every exchange
│   ├── assertions.py                 envelope, task, user, pagination assertions
│   ├── phases.py                     phase names, ports, container names
│   ├── report.py                     the per-language phase summary
│   ├── seed.py                       the 45-task corpus, as data
│   ├── util.py                       instants, sampling, percentiles
│   ├── fakejwt.py                    forged tokens for the negative auth tests
│   ├── prom.py                       Prometheus query client
│   ├── dockerutil.py                 SIGTERM, container env — best effort
│   ├── test_phase0_scaffold.py       envelope + health probes
│   ├── test_phase1_auth.py           registration, login, tokens
│   ├── test_phase1_tasks.py          CRUD, ownership isolation
│   ├── test_phase1_pagination.py     paging, filtering, sorting
│   ├── test_phase2_observability.py  traces, RED metrics, bucket boundaries
│   ├── test_phase3_database.py       p95, N+1, soft delete, concurrency
│   ├── test_phase4_cache.py          cache correctness, rate limiting
│   ├── test_phase5_resilience.py     idempotency, body limits, shutdown
│   ├── test_phase6_events.py         outbox, Valkey Streams, transport down
│   ├── test_phase7_security.py       headers, token families, login timing
│   ├── test_phase9_realtime.py      WebSocket fan-out
│   ├── test_phase10_attachments.py   multipart and presigned uploads
│   ├── test_appendix_kafka.py        OPTIONAL Kafka parity (-m appendix)
│   └── test_differential.py          all five, one scenario, one answer
└── e2e/
    └── test_user_journeys.py         full journeys rather than endpoint units
```

---

## The differential test

The strongest check in the project, and the one that does not exist in a
single-language codebase. It sends an identical scenario to all five servers and
asserts the answers are **structurally identical**: same status code, same key
sets, same types, same nullability.

```bash
pytest tests/ -m differential          # requires --impl all (the default)
```

Volatile values are replaced by a **shape signature** rather than a type name:

```
2026-08-15T00:00:00.000Z  →  <ts:9999-99-99T99:99:99.999Z>
2026-08-15T00:00:00       →  <ts:9999-99-99T99:99:99>          ← still diverges
tsk_9fA2xR                →  <id:tsk_…>
```

So the C#-emits-no-milliseconds case, the Go-omits-a-null-field case and the
Rust-returns-pageSize-as-a-string case are all caught, while genuinely unique
values are not compared. A failure names the implementation and the field:

```
implementations disagree (reference: go).
  step 'live': csharp diverges from go
    meta.timestamp: go='<ts:9999-99-99T99:99:99.999Z>'  csharp='<ts:9999-99-99T99:99:99>'
    data.extra:     go='<absent>'                       csharp=True
```

`check-phase.sh` includes the differential test in every phase from 1 onwards,
because agreement is not something you achieve once. It reports under **PHASE 1**
with the pseudo-implementation name `differential`.

---

## Markers

`--strict-markers` is on: a typo'd marker is an error, not a silent
"0 tests selected".

| Marker | Meaning |
|---|---|
| `phase0` … `phase11` | Which phase the test belongs to |
| `differential` | Cross-implementation comparison; needs `--impl all` |
| `e2e` | A full journey rather than a single endpoint |
| `slow` | More than ~10 s. `-m "not slow"` |
| `docker` | Needs the Docker CLI (signals, container env) |
| `destructive` | Stops a container or exhausts a rate-limit bucket |

A useful everyday filter:

```bash
pytest tests/ -m "phase4 and not slow and not docker" --impl go
# or simply
scripts/check-phase.sh 4 go --fast
```

---

## Fixtures

| Fixture | Scope | What you get |
|---|---|---|
| `impl` | session param | The language name; every test using it runs once per selected implementation |
| `api` | function | An unauthenticated client for one implementation |
| `user` | function | A freshly registered, authenticated user with a unique email |
| `second_user` | function | A second independent user, for ownership isolation |
| `task` | function | A task owned by `user` |
| `new_client` | function | Factory for extra independent clients (concurrency tests) |
| `seeded_user` | module | One user with the deterministic 45-task corpus |
| `db` | function | A live psycopg connection, or a clear skip |
| `clean_db` | function | `db` plus teardown of the accounts this test created |
| `valkey` | function | A Redis/Valkey client, or a clear skip |
| `events_stream` | function | The phase 6 task-events stream name, discovered on the live instance |
| `events_group` | function | The expected consumer group name |
| `events_dlq` | function | `{events_stream}:dlq` |
| `prometheus_url` | session | A reachable Prometheus, or a clear skip |
| `kafka_brokers` | function | Appendix only: reachable brokers, or a skip unless `--kafka-brokers` is passed |
| `all_impl_clients` | session | Every reachable implementation at once (differential only) |

---

## Rules the suite follows

**Hermetic.** Every test creates its own user with a UUID email and its own
data. Nothing depends on seed data or on another test having run.

**Parallel-safe.** `-n auto` works. The few tests that fight over shared state —
the rate-limit buckets, container restarts — carry
`@pytest.mark.xdist_group(...)`, so run them with `--dist loadgroup`:

```bash
pytest tests/ -m phase4 -n auto --dist loadgroup
```

**Order-independent.** No test relies on another test's side effects.

**Skips, not stack traces.** A missing service produces
`go-api not reachable at :8001, is it running?`, not a connection-refused
traceback.

**Generous timing thresholds.** Every timing assertion samples repeatedly and
compares medians or p95s. A flaky suite is worse than no suite — if a threshold
here ever fires spuriously, widen it rather than retrying it.

---

## Infrastructure each phase needs

| Phase | Beyond the API itself |
|---|---|
| 0, 1 | Postgres (one test in phase 0 also reads `pg_stat_statements`) |
| 2 | Prometheus + the OTel collector (`docker-compose.observability.yml`) |
| 3 | Postgres, direct, with `pg_stat_statements` |
| 4 | Valkey |
| 5 | Docker CLI, for the graceful-shutdown tests |
| 6 | Valkey Streams + Postgres (`outbox` table) |
| 7 | Nothing extra; the timing test is slow because `/auth/*` is 10/min |
| 10 | Nothing extra |
| 11 | SeaweedFS, reachable from the test process |

Anything missing produces a skip that names the service and the command to start
it. Absent infrastructure never counts as a failed phase.

---

## Adding a test

1. Put it in the file for its phase; the module-level `pytestmark` supplies the
   marker.
2. Take `api`, `user` or `seeded_user` — never build a client by hand.
3. Assert through the helpers in `assertions.py`, which already know the
   envelope and already print the exchange on failure.
4. Write the failure message for someone who has not read the spec: state the
   rule, then what happened.
5. Anything over ~10 s gets `@pytest.mark.slow`.

```python
def test_a_deleted_task_leaves_the_totals_correct(user):
    created = [user.create_task(f"Task {i}").expect(201).task for i in range(5)]
    user.delete_task(created[0]["id"]).expect(200)

    resp = user.list_tasks(pageSize=100)
    assert_task_list(resp)
    assert resp.pagination["totalItems"] == 4, (
        f"{user.impl}: totalItems is {resp.pagination['totalItems']} after deleting "
        f"1 of 5. The COUNT query needs the same deleted_at predicate as the SELECT."
    )
```

---

## Relationship to Schemathesis

This suite checks *semantics*: that a 429 arrives after 100 requests, that user
B gets a 404 on user A's task, that the five agree with each other. Schemathesis
checks *shape*, generated straight from the OpenAPI document, and is driven by
`scripts/conformance.sh` rather than pytest. Both are needed; neither replaces
the other.
