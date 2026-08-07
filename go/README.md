# TaskFlow — Go

Go 1.26 · `chi` v5 · `pgx/v5` (`pgxpool`)

This is a **skeleton**, not an application. It starts, connects to Postgres,
serves the three health probes for real, and returns `501 NOT_IMPLEMENTED` for
every other `/api/v1` route. That 501 is deliberate — the conformance suite
should fail loudly and specifically until you implement each endpoint.

Runs on host port **8001** under compose; listens on **8080** inside the container.

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
export OTEL_SERVICE_NAME=taskflow-go
export LOG_LEVEL=info

go run ./cmd/server
```

Or copy the repository-root `.env.example` to `.env` and `set -a; . ./.env; set +a`.

Check it:

```bash
curl -s localhost:8080/api/v1/health/live    | jq   # 200, no dependency checks
curl -s localhost:8080/api/v1/health/ready   | jq   # 200 if SELECT 1 works, else 503
curl -s localhost:8080/api/v1/health/startup | jq   # 200 once the pool is up
curl -s localhost:8080/api/v1/health         | jq   # alias of /health/ready
curl -si localhost:8080/api/v1/tasks         | head -1   # HTTP/1.1 501 Not Implemented
```

`DATABASE_URL` is required and the process exits immediately without it. Failing
at startup beats failing on the first request that needs the value.

## Run the tests

```bash
go test ./...                 # nothing to run yet — write the first test in Phase 1
go test -race -cover ./...    # what CI runs
go vet ./...
golangci-lint run             # config in .golangci.yml
```

`golangci-lint` is not vendored; install it with
`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest`.

## Layout

```
cmd/
  server/main.go          Entry point: config → pool → router → serve → graceful shutdown.
  healthcheck/main.go     Static binary for the container HEALTHCHECK. Distroless has no curl.
internal/
  config/config.go        Environment parsing. Fails fast on missing/malformed values.
  handlers/health.go      The three probes. Readiness caches its result for 1s (OBS5.4).
  httpx/envelope.go       The response envelope, request/trace IDs, the 501 handler.
Dockerfile                Multi-stage → distroless/static, non-root, EXPOSE 8080.
.golangci.yml             Lint config. errcheck and contextcheck earn their keep here.
```

Directories that do **not** exist yet, and the phase that creates them:

| Path | Phase | What lives there |
|---|---|---|
| `internal/models/` | 1 | Domain structs and their validation tags |
| `internal/repository/` | 1 | SQL. Parameterised, always. Sort/filter fields allow-listed (SEC3.3) |
| `internal/service/` | 1 | Business logic, transaction boundaries |
| `internal/middleware/` | 1 | auth, cors, bodylimit, security_headers, recovery |
| `internal/telemetry/` | 2 | OTel tracing, metrics, log correlation |
| `internal/cache/` | 4 | Valkey client, cache-aside, rate limiting |
| `internal/resilience/` | 5 | Timeouts, retries, circuit breakers |
| `internal/events/` | 6 | Outbox, producer, consumer |
| `internal/storage/` | 10 | S3 presigned URLs |
| `internal/realtime/` | 10 | WebSocket hub + pub/sub bridge |

Note that `migrations/` lives at the **repository root**, not here. One schema,
one migration tool — five copies is a divergence waiting to happen (C7).

## What to build next

**Phase 1 — Core API** (`docs/learning-roadmap.md`). The long one, 5–7 weeks.
FR1, FR2 and FR5 from the requirements spec. No cache, no events, no WebSocket.

Work in this order; each step deletes some of the 501 surface:

1. **Envelope and error taxonomy first.** `internal/httpx/envelope.go` already
   has the success/error shapes. Add the error code table — `VALIDATION_ERROR`,
   `UNAUTHORIZED`, `FORBIDDEN`, `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`,
   `INTERNAL_ERROR` — and map each to a status code in one place.
2. **`POST /auth/register`, `POST /auth/login`, `POST /auth/refresh`.** bcrypt
   at cost 12, `golang-jwt/v5`, access 15m / refresh 7d.
3. **Task CRUD** — `GET|POST /tasks`, `GET|PATCH|DELETE /tasks/{id}`. Ownership
   is enforced in the query's WHERE clause, not in a Go `if` after the fetch.
4. **Validation** with `go-playground/validator`, surfacing field-level errors
   in `error.details`.
5. **Middleware**: request ID (done), recovery, CORS, security headers, body
   limit, auth.

Mount each real router in `cmd/server/main.go` **above** the `r.HandleFunc("/*",
httpx.NotImplemented)` catch-all. When that catch-all stops being reachable,
Phase 1 is done.

**Gate:** the conformance suite passes against this service —
`./scripts/conformance.sh go`.

Search the tree for `TODO(Phase` to find every marked extension point.
