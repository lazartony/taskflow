# TaskFlow

**Learn production backend engineering by building a real one — with the tests, benchmarks and infrastructure already written.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Languages](https://img.shields.io/badge/languages-Go%20%C2%B7%20Rust%20%C2%B7%20Python%20%C2%B7%20C%23%20%C2%B7%20TypeScript-informational)](#one-language-or-five)
[![Phases](https://img.shields.io/badge/phases-11-success)](docs/learning-roadmap.md)

> ### Written entirely by AI
>
> **Every file here was produced by an AI model** — the contract, the ~1,900 tests, the five
> skeletons, the harness, the CI, and all of the documentation.
>
> The gates are run, not asserted: Phase 0 passes 35/35 for all five languages, `make validate`
> and `make lint` are clean, and CI proves it on every push. The prose is a different matter —
> nobody reviewed it. The specs state opinions about pool sizing, sampling and cache
> invalidation with more confidence than an unreviewed document has earned, and the version
> pins and benchmark reasoning are where it is most likely to be subtly wrong.
>
> You do not have to trust any of it. The conformance suite either passes or it doesn't, and
> you can read every assertion.

Most backend tutorials teach you to build a CRUD API. Very few teach the part that actually distinguishes production work: knowing your service is healthy, keeping it up when a dependency isn't, proving a change made things faster, and reasoning about correctness when two systems have to agree.

TaskFlow gives you the scaffolding for all of that — **~1,900 conformance tests, an OpenAPI contract, a load-testing harness, profiling, chaos experiments, a full observability stack and working CI** — plus five deliberately unfinished services. You write the application. The tests tell you when you're done.

```bash
make setup && make up && make check PHASE=1 IMPL=go
```

```
  PHASE 1 — Core API
  ────────────────────────────────────────────────────────────
  go           ░░░░░░░░░░░░░░░░░░░░░░    0/213  213 not implemented

  First failures:
    test_phase1_auth.py::test_register_returns_201[go]
      → POST /api/v1/auth/register returned 501 NOT_IMPLEMENTED
    test_phase1_auth.py::test_duplicate_email_returns_409_conflict[go]
      → POST /api/v1/auth/register returned 501 NOT_IMPLEMENTED
```

**That red is your specification.** Every failing test names exactly one behaviour the API must have. Make them green, one at a time.

---

## What the tests actually check

The contract is specific in the places that are easy to get subtly wrong. Reading another user's task returns 404, not 403 — a 403 confirms the row exists and turns the ID space into an enumeration oracle. Pagination metadata is exact at the boundaries. An unknown email and a wrong password must return identical bodies *and* comparable timings.

Performance claims come with numbers, not adjectives: `make bench-cache` reports p50/p95/p99 before and after, the actual query counts from `pg_stat_statements`, and the arrival rate where the two curves diverge.

`make chaos N=3` stops PostgreSQL and checks that liveness still passes while readiness fails. Get that backwards and a recoverable database blip kills every replica.

Where guidance is genuinely contested — pool sizing, cache invalidation, exactly-once semantics, sampling — the specs give the trade-off rather than one answer.

---

## Start here

```bash
git clone <this repo> taskflow && cd taskflow
make setup      # .env with a generated JWT secret, test deps, tool check
make up         # Postgres, Valkey, S3 + your APIs  (~400 MB, no message broker)
make check      # phase 0 — does the scaffold hold up?
```

Phase 0 should be green before you write a line: the skeletons already implement health probes, connection pooling and graceful shutdown, and return `501` for everything else.

Then open **[`docs/learning-roadmap.md`](docs/learning-roadmap.md)** and start Phase 1.

**Requirements:** Docker with Compose v2, `make`, Python 3.11+ (for the conformance harness only — the Python *service* targets 3.13, and every toolchain runs in a container). That's all — every toolchain runs in a container, so you don't need Go, Rust, .NET or Node installed unless you want to build outside Docker. Works on Linux, macOS (Intel and Apple Silicon) and Windows via WSL2.

On macOS, `brew install bash` as well if you plan to run `make bench`, `make bench-quick`, `make bench-cache` or `make soak`: those four keep per-implementation results in an associative array, which needs bash 4, and Apple still ships 3.2. Everything else — including `make up`, `make check`, `make validate`, `make lint`, `make profile` and `make pin-actions` — runs on the stock shell, and the four that don't say so up front instead of failing halfway.

---

## One language or five

Five is the default and it's the more interesting project — five independent implementations of one contract, plus a differential test that proves they agree. But **one language is a fully supported path**, not a degraded one:

```bash
make languages LANGS=go          # or go,rust  or  all
```

One line in `.env` changes. Nothing is deleted, and the tools that report *progress* narrow to match — `make check`, `make progress`, `make status`. You keep all eleven phases and the entire harness. You lose exactly one thing: `make diff`, which needs at least two implementations to compare, and skips with an explanation rather than failing.

`make bench` and `make profile` are the exceptions: they still default to all five, because a benchmark's whole job is comparison. Name the one you want — `make bench IMPL=go` — or they will wait on services that were never started.

---

## What's already built

| | What | Where |
|---|---|---|
| ✅ | **OpenAPI 3.1 contract** — 20 operations, every error documented, machine-validated | `docs/openapi.yaml` |
| ✅ | **~1,900 conformance tests**, tagged by phase, parameterised over your languages | `tests/conformance/` |
| ✅ | **Differential test** — proves independent implementations return identical shapes | `tests/conformance/test_differential.py` |
| ✅ | **k6 load harness** — open-loop executors: steady, ramp, spike, soak, capacity | `tests/load/` |
| ✅ | **Cache A/B benchmark** — what caching buys, in latency *and* query counts | `scripts/bench-cache.sh` |
| ✅ | **Profiling** — CPU and heap flamegraphs per language, plus a cache-on/off diff | `scripts/profile.sh` |
| ✅ | **Chaos experiments** — 12 catalogued, 8 scripted with pass/fail verdicts; 4 print what they need and skip | `scripts/chaos.sh` |
| ✅ | **CI** — works today, gets more useful as you build, never needs rewriting | `.github/workflows/ci.yml` |
| ✅ | **Observability stack** — OTel Collector, Prometheus, Loki, Tempo, Pyroscope, Grafana | `observability/` |
| ✅ | **Infrastructure** — Postgres 18, Valkey 9 (cache + event streams), S3-compatible storage | `docker-compose.infra.yml` |
| ✅ | **Migrations** — plain SQL, one tool, up→down→up verified in CI | `migrations/` |
| ✅ | **GCRA rate limiter** as a Valkey Function — heavily commented, loaded on startup, syntax-checked in CI. Its *behaviour* is asserted by the Phase 4 tests you have to make pass | `infrastructure/valkey/functions/` |
| ✅ | **Five runnable skeletons** — health endpoints, pooling, graceful shutdown | `go/ rust/ python/ csharp/ typescript/` |

**You build the application.** Phases 1 through 11.

---

## The loop

```bash
make check PHASE=1 IMPL=go     # what's left?
# ... write code ...
make restart IMPL=go           # rebuild that one service
make check PHASE=1 IMPL=go     # again
```

When a phase is green everywhere:

```bash
make diff        # do the implementations agree?
make progress    # the whole board
```

```
  TaskFlow progress

  phase                           go          rust        python      csharp      typescript
  ──────────────────────────────────────────────────────────────────────────────────────────
   0. Scaffold                    ██ 35/35    ██ 35/35    ██ 35/35    ██ 35/35    ██ 35/35
   1. Core API                    ██ 213/213  ██ 213/213  ▒▒ 148/213  ░░ 12/213   ██ 213/213
   2. Observability               ██ 12/12    ░░ 3/12     —           —           ▒▒ 8/12
   3. Database Depth              ░░ 4/11     —           —           —           —
```

---

## Commands

`make help` lists everything. The ones you'll use:

| Command | |
|---|---|
| `make check PHASE=n IMPL=x` | **The main loop.** One phase, one language |
| `make progress` | Whole-project dashboard |
| `make languages LANGS=go` | Work in one language (or `go,rust`, or `all`) |
| `make diff` | Differential test — do your implementations agree? |
| `make bench-cache` | **The cache A/B** — latency and database query counts, before and after |
| `make bench` | Full benchmark with fair-comparison rules enforced |
| `make profile IMPL=go` | Flamegraphs under load |
| `make profile-diff IMPL=go` | Which stack frames disappear when caching is on |
| `make chaos N=3` | Chaos experiment 3 (the one that matters most) |
| `make soak IMPL=go` | Leak detection — the only test that finds them |
| `make seed SIZE=large` | 1,000 users × 100 tasks, deterministic |
| `make migrate-test` | Verify up → down → up leaves an identical schema |
| `make up-full` | Add the observability stack → Grafana on :3000 |

---

## Documentation

Start with the roadmap. The specs are references, consumed phase by phase rather than read front to back.

| | |
|---|---|
| **[Learning roadmap](docs/learning-roadmap.md)** | **Start here.** 11 phases, what to build, what each teaches, the command that proves you're done, per-language reference links |
| [OpenAPI contract](docs/openapi.yaml) | Normative. When docs and this disagree, this wins |
| [Requirements](docs/requirements-specification.md) + [addendum](docs/requirements-addendum.md) | What the system does |
| [API specification](docs/api-specification.md) | The HTTP surface in prose — envelope, errors, status-code rules |
| [Database schema](docs/database-schema.md) | Tables, indexes, and why each index exists |
| [Observability spec](docs/observability-specification.md) | Telemetry contract, RED/USE metrics, SLOs, cardinality rules |
| [Infrastructure spec](docs/infrastructure-specification.md) | Caching, rate limiting, the outbox pattern, object storage, Kafka appendix |
| [Resilience & security spec](docs/resilience-and-security-specification.md) | Timeouts, breakers, shutdown, threat model, supply chain |
| [Testing & CI spec](docs/cicd-and-testing-specification.md) | Test strategy, conformance design, coordinated omission |
| [Project structure](docs/project-structure-v2.md) | Where everything lives, and what is deliberately absent |
| [Benchmark methodology](benchmarks/README.md) | **Read before trusting any number you produce** |

---

## Some decisions worth knowing about

These are the kind of judgement calls the project exists to teach, so they're documented rather than silent.

**One migration tool, not five ORMs.** Five ORMs generating migrations against one schema conflict — EF Core and Prisma each want to "fix" what the other did. `migrations/` is plain SQL applied by golang-migrate; every implementation just connects to the result.

**Valkey, not Redis.** Redis relicensed to RSALv2/SSPLv1 in 2024 and added AGPLv3 in 2025. Valkey is the Linux Foundation fork, still BSD-3-Clause and wire-compatible. Everything here works on either — swap the image. See [NOTICE.md](NOTICE.md).

**SeaweedFS, not MinIO.** `minio/minio` was archived by its owner in April 2026 and is read-only. Most tutorials still recommend it. Most tutorials still recommend it.

**Valkey Streams for events, not Kafka.** Phase 6 teaches the transactional outbox, at-least-once delivery and idempotent consumers — all of which Streams does, on a container you already run for caching. Kafka would add a broker, ~1 GB of RAM and a different client per language, for partitioning this app doesn't need. It's still there as an appendix behind a compose profile.

**Open-loop load testing.** The k6 harness uses arrival-rate executors. Closed-loop generators (`hey`, plain `wrk`, `ab`) suffer coordinated omission: when the server stalls they stop sending, so the requests that *would* have been slow are never issued. A closed-loop tool can report p99 = 80 ms on a workload whose real p99 is over a second.

**`CHECK (due_date > NOW())` is not in the schema.** It looks reasonable and isn't valid: `NOW()` is not `IMMUTABLE`, so rows become retroactively invalid as time passes and `pg_dump`/restore fails on data that was fine when written. "Due date must be in the future" is an application-layer rule.

---

## If your machine is struggling

The default stack is ~400 MB and 12 containers. You rarely need all of it:

```bash
make languages LANGS=go    # stop building the other four entirely
make up-one IMPL=go        # Postgres + Valkey + S3 + one API
```

Skip the observability stack until Phase 2 — `make up` rather than `make up-full`.

---

## Getting unstuck

| Symptom | Try |
|---|---|
| `make check` says "not reachable" | `make status` — is the container up and healthy? |
| A test fails and you can't tell why | `pytest tests/conformance/test_phase1_auth.py -k <name> --impl go -vv` prints the full exchange |
| One language disagrees with the others | `make diff` names which one and how |
| Everything is slow | `make profile IMPL=go` — read the flamegraph before guessing |
| Container won't start | `docker compose logs <service>` — usually a port conflict or a bad `.env` |
| `bind: address already in use` on 5432 or 6379 | Something else already holds the port. Stop it, or move ours — but move it in **all three** places that must agree: the `ports:` mapping in `docker-compose.yml` (or `docker-compose.infra.yml`), `DATABASE_URL`/`VALKEY_URL` in `.env`, and `TASKFLOW_POSTGRES_DSN`/`TASKFLOW_VALKEY_URL` for the test harness. Change only the mapping and `make migrate` will happily talk to whatever *is* on 5432 |
| Something in the docs looks out of date | It probably is — versions were verified in August 2026. Please open an issue |

---

## Contributing

Bug fixes, spec corrections, version-drift updates, better error messages, platform fixes and new chaos experiments are all welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

**Please don't submit completed phase implementations.** That's the exercise. If you want to share what you built, open a Discussion and it can go on a community list instead.

---

## Support expectations

This is a learning project maintained in spare time, not a product. Issues may sit for a while. Before opening one:

1. Read the failing test's message — for phase questions it's usually the answer
2. Run `make status` and `make validate`
3. Search existing issues and Discussions

Stuck on a phase? Use [Discussions](../../discussions), not an issue.

---

## Licence

MIT — see [LICENSE](LICENSE). Third-party dependency licences, including the ones with non-obvious situations, are catalogued in [NOTICE.md](NOTICE.md).
