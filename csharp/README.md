# TaskFlow — C#

.NET 10 (LTS) · ASP.NET Core Minimal APIs · `Npgsql`

This is a **skeleton**, not an application. It starts, connects to Postgres,
serves the three health probes for real, and returns `501 NOT_IMPLEMENTED` for
every other `/api/v1` route. That 501 is deliberate — the conformance suite
should fail loudly and specifically until you implement each endpoint.

Runs on host port **8004** under compose; listens on **8080** inside the container.

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
export OTEL_SERVICE_NAME=taskflow-csharp
export LOG_LEVEL=info

dotnet run --project TaskFlow.Api
# or, reloading on save:
dotnet watch --project TaskFlow.Api
```

Check it:

```bash
curl -s localhost:8080/api/v1/health/live    | jq   # 200, no dependency checks
curl -s localhost:8080/api/v1/health/ready   | jq   # 200 if SELECT 1 works, else 503
curl -s localhost:8080/api/v1/health/startup | jq   # 200 once the pool is up
curl -s localhost:8080/api/v1/health         | jq   # alias of /health/ready
curl -si localhost:8080/api/v1/tasks | head -1      # HTTP/1.1 501 Not Implemented
```

### The connection-string gotcha

The other four services take `DATABASE_URL` straight to their driver, because
those drivers parse the `postgresql://user:pass@host:5432/db` URI form.
**Npgsql does not** — it wants semicolon-delimited key/value pairs
(`Host=…;Username=…;Password=…;Database=…`). `Config/AppConfig.cs` translates
the URI so this service reads the same env var as the other four.

`ConnectionStrings__DefaultConnection` takes precedence when set, which is how
`docker-compose.yml` configures this service. Either works; the URI path is
there so a plain `.env` shared across all five languages does the right thing.

## Run the tests

```bash
dotnet build                      # restore + compile
dotnet test                       # nothing to run yet — write the first in Phase 1
dotnet format --verify-no-changes # style gate
dotnet build -warnaserror         # what CI should run
```

`TreatWarningsAsErrors` is currently **off** in the csproj. Turn it on in
Phase 1, once you have decided which analyzer rules you actually want — over a
skeleton it mostly produces noise about things this code does not do yet.

## Layout

```
TaskFlow.sln                        Solution. One project today; tests join it in Phase 1.
TaskFlow.Api/
  Program.cs                        Entry point: config → data source → middleware → routes
                                    → graceful shutdown. Also holds AppLog (the JSON logger)
                                    and HealthCheckCommand (the --healthcheck mode).
  Config/AppConfig.cs               Environment parsing, including the DATABASE_URL → Npgsql
                                    connection-string translation. Throws on bad values.
  Endpoints/HealthEndpoints.cs      The three probes plus HealthChecker, whose readiness
                                    result is cached for 1s (OBS5.4).
  Http/Envelope.cs                  Response envelope, request/trace IDs, the 501 handler.
  appsettings.json                  Only what the host reads before AppConfig runs.
Dockerfile                          Multi-stage → aspnet:10.0-noble-chiseled-extra, non-root.
```

Folders that do **not** exist yet, and the phase that creates them:

| Path | Phase | What lives there |
|---|---|---|
| `TaskFlow.Api/Endpoints/AuthEndpoints.cs`, `TaskEndpoints.cs` | 1 | The endpoints that replace the 501 |
| `TaskFlow.Api/Models/` | 1 | Domain records and FluentValidation validators |
| `TaskFlow.Api/Repository/` | 1 | SQL. Parameterised; sort/filter fields allow-listed (SEC3.3) |
| `TaskFlow.Api/Middleware/` | 1 | auth, cors, body limit, security headers |
| `TaskFlow.Api/Telemetry/` | 2 | OTel tracing, metrics, log correlation |
| `TaskFlow.Api/Cache/` | 4 | Valkey client, cache-aside, rate limiting |
| `TaskFlow.Api/Events/` | 6 | Outbox, producer, consumer |
| `TaskFlow.Api/Storage/` | 10 | S3 presigned URLs |
| `TaskFlow.Tests/` | 1 | xUnit + Testcontainers |

Note that `migrations/` lives at the **repository root**, not here. One schema,
one migration tool — five copies is a divergence waiting to happen (C7). In
particular, do **not** add EF Core migrations; that would be a second tool
owning the same schema.

## Container healthcheck

The chiselled runtime image has no shell and no `curl`, so the `HEALTHCHECK`
re-invokes the app's own executable:

```dockerfile
HEALTHCHECK CMD ["/app/TaskFlow.Api", "--healthcheck"]
```

`docker-compose.yml`'s shared `x-healthcheck` anchor is `["CMD", "/healthcheck"]`,
which fits the Go and Rust images (they ship a standalone static binary at that
path). Override it for this service:

```yaml
  csharp-api:
    healthcheck:
      test: ["CMD", "/app/TaskFlow.Api", "--healthcheck"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 30s
```

## What to build next

**Phase 1 — Core API** (`docs/learning-roadmap.md`). The long one, 5–7 weeks.
FR1, FR2 and FR5 from the requirements spec. No cache, no events, no WebSocket.

Work in this order; each step deletes some of the 501 surface:

1. **Error taxonomy.** `Http/Envelope.cs` already has the success/error shapes.
   Add the code table — `VALIDATION_ERROR`, `UNAUTHORIZED`, `FORBIDDEN`,
   `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`, `INTERNAL_ERROR` — and an
   `IExceptionHandler` that renders unhandled exceptions in *your* envelope
   rather than ASP.NET's default `ProblemDetails`. That default is the single
   most common conformance failure in this language.
2. **`POST /auth/register|login|refresh`.** BCrypt cost 12, `JwtBearer`,
   access 15m / refresh 7d.
3. **Task CRUD** — `GET|POST /tasks`, `GET|PATCH|DELETE /tasks/{id}`. Ownership
   is enforced in the query's WHERE clause, not in an `if` after the fetch.
4. **Validation** with FluentValidation, surfacing field-level errors in
   `error.details`.
5. **Middleware**: request ID (done), CORS, security headers, body limit, auth.

Map each real endpoint group in `Program.cs`. Unlike the other four services
there is no ordering to maintain — ASP.NET routing prefers the more specific
route, so `/api/v1/{**rest}` yields automatically as soon as a real endpoint
matches. When that catch-all stops being reachable, Phase 1 is done.

**Gate:** the conformance suite passes against this service —
`./scripts/conformance.sh csharp`.

Search the tree for `TODO(Phase` to find every marked extension point.
