# TaskFlow — Rust

Rust 1.97 (edition 2021) · `axum` 0.8 · `sqlx` 0.9 · `tokio` · `tracing`

This is a **skeleton**, not an application. It starts, connects to Postgres,
serves the three health probes for real, and returns `501 NOT_IMPLEMENTED` for
every other `/api/v1` route. That 501 is deliberate — the conformance suite
should fail loudly and specifically until you implement each endpoint.

Runs on host port **8002** under compose; listens on **8080** inside the container.

---

## Run locally without Docker

You need a PostgreSQL 18 on :5432. The compose file brings one up:

```bash
docker compose up -d postgres migrate
```

Then, from this directory:

```bash
export DATABASE_URL="postgresql://postgres:password@localhost:5432/taskflow_dev"
export DATABASE_POOL_SIZE=10
export PORT=8080
export OTEL_SERVICE_NAME=taskflow-rust
export LOG_LEVEL=info

cargo run                 # debug build, fast to compile
cargo run --release       # what the benchmarks measure — always use this for timing
```

Or copy the repository-root `.env.example` to `.env` and `set -a; . ./.env; set +a`.

Check it:

```bash
curl -s localhost:8080/api/v1/health/live    | jq   # 200, no dependency checks
curl -s localhost:8080/api/v1/health/ready   | jq   # 200 if SELECT 1 works, else 503
curl -s localhost:8080/api/v1/health/startup | jq   # 200 once the pool is up
curl -s localhost:8080/api/v1/health         | jq   # alias of /health/ready
curl -si localhost:8080/api/v1/tasks | head -1      # HTTP/1.1 501 Not Implemented
```

`DATABASE_URL` is required and the process exits immediately without it. Failing
at startup beats failing on the first request that needs the value.

`LOG_LEVEL` seeds the tracing filter, but `RUST_LOG` overrides it when set —
handy for `RUST_LOG=debug,sqlx=info` while debugging a query.

## Run the tests

```bash
cargo check --all-targets    # the fast feedback loop
cargo test                   # nothing to run yet — write the first test in Phase 1
cargo clippy -- -D warnings  # what CI runs
cargo fmt --check
```

`sqlx` is used through the runtime `sqlx::query()` API rather than the
compile-time-checked `query!` macros. The macros need a live database (or a
committed `.sqlx/` offline cache) at **compile** time, which would make
`cargo check` fail on a fresh clone. Revisit that trade-off in Phase 1 — the
macros are genuinely excellent once the schema is stable.

## Layout

```
src/
  main.rs               Entry point: config → pool → router → serve → graceful shutdown.
                        Also holds logging setup and the log_info! macro.
  config.rs             Environment parsing. Returns Err on missing/malformed values.
  envelope.rs           Response envelope, ReqCtx, the request-ID middleware, the 501 fallback.
  handlers/mod.rs       Handler module tree.
  handlers/health.rs    The three probes. Readiness caches its result for 1s (OBS5.4).
  bin/healthcheck.rs    Container HEALTHCHECK. std-only, no HTTP crate. Distroless has no curl.
Dockerfile              Multi-stage → distroless/cc, non-root, EXPOSE 8080.
Cargo.toml              Deps and the release profile (LTO, strip, panic=abort).
```

Modules that do **not** exist yet, and the phase that creates them:

| Path | Phase | What lives there |
|---|---|---|
| `src/handlers/auth.rs`, `tasks.rs` | 1 | The handlers that replace the 501 |
| `src/models/` | 1 | Domain types and their `validator` derives |
| `src/repository/` | 1 | SQL. Sort/filter fields allow-listed, never interpolated (SEC3.3) |
| `src/middleware/` | 1 | auth, cors, body limit, security headers (mostly `tower-http`) |
| `src/telemetry/` | 2 | OTel tracing, metrics, log correlation |
| `src/cache/` | 4 | Valkey client, cache-aside, rate limiting |
| `src/resilience/` | 5 | Timeouts, retries, circuit breakers |
| `src/events/` | 6 | Outbox, producer, consumer |
| `src/storage/` | 10 | S3 presigned URLs |

Note that `migrations/` lives at the **repository root**, not here. One schema,
one migration tool — five copies is a divergence waiting to happen (C7). In
particular, do **not** adopt `sqlx migrate`; it would be a second tool owning
the same schema.

## What to build next

**Phase 1 — Core API** (`docs/learning-roadmap.md`). The long one, 5–7 weeks.
FR1, FR2 and FR5 from the requirements spec. No cache, no events, no WebSocket.

Work in this order; each step deletes some of the 501 surface:

1. **Error taxonomy.** `src/envelope.rs` already has the success/error shapes.
   Add an `AppError` enum with a `IntoResponse` impl mapping each variant to a
   status and a code — `VALIDATION_ERROR`, `UNAUTHORIZED`, `FORBIDDEN`,
   `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`, `INTERNAL_ERROR`. Doing this first
   is what makes `?` usable in every handler afterwards.
2. **`POST /auth/register|login|refresh`.** `argon2` or `bcrypt`,
   `jsonwebtoken` 9, access 15m / refresh 7d.
3. **Task CRUD** — `GET|POST /tasks`, `GET|PATCH|DELETE /tasks/{id}`. Ownership
   is enforced in the query's WHERE clause, not in an `if` after the fetch.
4. **Validation** with `validator`, surfacing field-level errors in
   `error.details`.
5. **Middleware**: request ID (done), CORS, security headers, body limit, auth.

Nest each real router in `src/main.rs` **above** the `.fallback(not_implemented)`
call. When that fallback stops being reachable, Phase 1 is done.

**Gate:** the conformance suite passes against this service —
`./scripts/conformance.sh rust`.

Search the tree for `TODO(Phase` to find every marked extension point.
