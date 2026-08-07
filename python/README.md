# TaskFlow — Python

FastAPI · `asyncpg` · `uvicorn`

This is a **skeleton**, not an application. It starts, connects to Postgres,
serves the three health probes for real, and returns `501 NOT_IMPLEMENTED` for
every other `/api/v1` route. That 501 is deliberate — the conformance suite
should fail loudly and specifically until you implement each endpoint.

Runs on host port **8003** under compose; listens on **8080** inside the container.

> **A note on the Python version.** The roadmap targets 3.12 for local
> development, but the runtime image (`gcr.io/distroless/python3-debian12`)
> ships CPython **3.11**, and `asyncpg` is a C extension whose wheel is built
> against a specific ABI. The Dockerfile therefore builds its venv on
> `python:3.11-slim-bookworm` so builder and runtime match. `requires-python`
> is `>=3.11` so the same tree works either way. If you move to a newer
> distroless base, bump the builder tag **and** the `site-packages` path in
> `PYTHONPATH` together.

---

## Run locally without Docker

You need a PostgreSQL 17 on :5432. The compose file brings one up:

```bash
docker compose up -d postgres migrate
```

Then, from this directory:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"

export DATABASE_URL="postgresql://postgres:password@localhost:5432/taskflow_dev"
export DATABASE_POOL_SIZE=10
export PORT=8080
export OTEL_SERVICE_NAME=taskflow-python
export LOG_LEVEL=info

python -m app.main
# or, with reload while you work:
uvicorn app.main:app --reload --port 8080
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

## Run the tests

```bash
pytest                       # nothing to run yet — write the first test in Phase 1
pytest --cov=app             # what CI runs
ruff check .                 # lint; ASYNC rules catch blocking calls in async def
ruff format .
mypy app                     # strict mode; see [tool.mypy] in pyproject.toml
python -m py_compile app/*.py app/routers/*.py   # the fastest syntax check
```

## Layout

```
app/
  main.py             Entry point: lifespan pool → middleware → routers → uvicorn.
                      Also holds the JSON log formatter and the request middleware.
  config.py           Environment parsing into a frozen dataclass. Raises on bad values.
  db.py               The asyncpg pool. min_size/max_size map to the DATABASE_* env vars.
  envelope.py         Response envelope, request/trace IDs, the 501 handler.
  routers/health.py   The three probes. Readiness caches its result for 1s (OBS5.4).
scripts/
  healthcheck.py      Container HEALTHCHECK. Distroless has no curl. Stdlib only.
Dockerfile            Multi-stage → distroless/python3, venv copied in, non-root.
pyproject.toml        Deps, ruff, mypy and pytest config in one file.
```

Modules that do **not** exist yet, and the phase that creates them:

| Path | Phase | What lives there |
|---|---|---|
| `app/routers/auth.py`, `tasks.py` | 1 | The route handlers that replace the 501 |
| `app/schemas/` | 1 | Pydantic v2 models — request bodies and response DTOs |
| `app/repository/` | 1 | SQL. Sort/filter fields allow-listed, never interpolated (SEC3.3) |
| `app/middleware/` | 1 | auth, cors, body limit, security headers |
| `app/telemetry/` | 2 | OTel tracing, metrics, log correlation |
| `app/cache/` | 4 | Valkey client, cache-aside, rate limiting |
| `app/events/` | 6 | Outbox, producer, consumer |
| `app/storage/` | 10 | S3 presigned URLs |

Note that `migrations/` lives at the **repository root**, not here. One schema,
one migration tool — five copies is a divergence waiting to happen (C7).

FastAPI's generated `/docs` is switched **off** (`docs_url=None`). The envelope
is hand-rolled, so the auto-generated schema would describe a response shape
this service does not return. `docs/openapi.yaml` is the normative contract.

## What to build next

**Phase 1 — Core API** (`docs/learning-roadmap.md`). The long one, 5–7 weeks.
FR1, FR2 and FR5 from the requirements spec. No cache, no events, no WebSocket.

Work in this order; each step deletes some of the 501 surface:

1. **Error taxonomy.** `app/envelope.py` already has the success/error shapes.
   Add the code table — `VALIDATION_ERROR`, `UNAUTHORIZED`, `FORBIDDEN`,
   `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`, `INTERNAL_ERROR` — and map each to
   a status code in one place. Add a `RequestValidationError` handler so
   Pydantic's 422 comes back in *your* envelope, not FastAPI's default shape —
   this is the single most common conformance failure in this language.
2. **`POST /auth/register|login|refresh`.** bcrypt cost 12, `pyjwt`,
   access 15m / refresh 7d.
3. **Task CRUD** — `GET|POST /tasks`, `GET|PATCH|DELETE /tasks/{id}`. Ownership
   is enforced in the query's WHERE clause, not in an `if` after the fetch.
4. **Validation** with Pydantic v2, surfacing field-level errors in
   `error.details`.
5. **Middleware**: request ID (done), CORS, security headers, body limit, auth.

Add each real router in `app/main.py` **above** the `catch_all` route — Starlette
matches in registration order, so the catch-all must stay last. When it stops
being reachable, Phase 1 is done.

**Gate:** the conformance suite passes against this service —
`./scripts/conformance.sh python`.

Search the tree for `TODO(Phase` to find every marked extension point.
