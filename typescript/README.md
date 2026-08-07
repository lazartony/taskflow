# TaskFlow — TypeScript

Node 24 · `Hono` 4 · `postgres` (porsager) · `tsx` for dev

This is a **skeleton**, not an application. It starts, connects to Postgres,
serves the three health probes for real, and returns `501 NOT_IMPLEMENTED` for
every other `/api/v1` route. That 501 is deliberate — the conformance suite
should fail loudly and specifically until you implement each endpoint.

Runs on host port **8005** under compose; listens on **8080** inside the container.

---

## Run locally without Docker

You need a PostgreSQL 18 on :5432. The compose file brings one up:

```bash
docker compose up -d postgres migrate
```

Then, from this directory:

```bash
npm install

export DATABASE_URL="postgresql://postgres:password@localhost:5432/taskflow_dev"
export DATABASE_POOL_SIZE=10
export PORT=8080
export OTEL_SERVICE_NAME=taskflow-typescript
export LOG_LEVEL=info

npm run dev      # tsx watch — reloads on save
npm start        # tsx, no watch
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

Note that `npm run dev` uses `tsx`, but the **image runs compiled JavaScript**
(`npm run build` → `node dist/index.js`). No transpiler in the runtime image.

## Run the tests

```bash
npm run typecheck        # tsc --noEmit — the fastest bug filter you have
npm run build            # tsc → dist/
npm test                 # node --test; nothing to run yet, write the first in Phase 1
```

`tsconfig.json` runs with `strict`, `noUncheckedIndexedAccess` and
`exactOptionalPropertyTypes` on. Turn any of them off only with a reason you
can defend — each catches a class of bug that otherwise reaches production.

## Layout

```
src/
  index.ts             Entry point: config → pool → router → serve → graceful shutdown.
                       Also holds the JSON logger and the request-log middleware.
  config.ts            Environment parsing. Throws on missing/malformed values.
  db.ts                The postgres.js pool. `max` is the pool size.
  envelope.ts          Response envelope, request/trace IDs, the 501 handler.
  routes/health.ts     The three probes. Readiness caches its result for 1s (OBS5.4).
scripts/
  healthcheck.cjs      Container HEALTHCHECK. Distroless has no curl. CommonJS on purpose.
Dockerfile             Multi-stage → distroless/nodejs24, non-root, EXPOSE 8080.
tsconfig.json          NodeNext ESM, strict.
```

Files that do **not** exist yet, and the phase that creates them:

| Path | Phase | What lives there |
|---|---|---|
| `src/routes/auth.ts`, `tasks.ts` | 1 | The route handlers that replace the 501 |
| `src/schemas/` | 1 | `zod` schemas — one per request body, reused as types |
| `src/repository/` | 1 | SQL. Sort/filter fields allow-listed, never interpolated (SEC3.3) |
| `src/middleware/` | 1 | auth, cors, bodyLimit, securityHeaders |
| `src/telemetry/` | 2 | OTel tracing, metrics, log correlation |
| `src/cache/` | 4 | Valkey client, cache-aside, rate limiting |
| `src/events/` | 6 | Outbox, producer, consumer |
| `src/storage/` | 10 | S3 presigned URLs |

Note that `migrations/` lives at the **repository root**, not here. One schema,
one migration tool — five copies is a divergence waiting to happen (C7).

## What to build next

**Phase 1 — Core API** (`docs/learning-roadmap.md`). The long one, 5–7 weeks.
FR1, FR2 and FR5 from the requirements spec. No cache, no events, no WebSocket.

The roadmap's stack for this language is `Hono` 4 + `drizzle-orm` + `jose` +
`zod`. This skeleton uses raw `postgres.js` rather than Drizzle — decide in
Phase 1 whether to add Drizzle on top or stay with tagged-template SQL. Either
is defensible; raw SQL keeps the comparison with the other four honest, Drizzle
buys you typed results.

Work in this order; each step deletes some of the 501 surface:

1. **Error taxonomy.** `src/envelope.ts` already has the success/error shapes.
   Add the code table — `VALIDATION_ERROR`, `UNAUTHORIZED`, `FORBIDDEN`,
   `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED`, `INTERNAL_ERROR` — and map each to
   a status code in one place.
2. **`POST /auth/register|login|refresh`.** bcrypt cost 12, `jose` for JWT,
   access 15m / refresh 7d.
3. **Task CRUD** — `GET|POST /tasks`, `GET|PATCH|DELETE /tasks/{id}`. Ownership
   is enforced in the query's WHERE clause, not in an `if` after the fetch.
4. **Validation** with `zod`, surfacing field-level errors in `error.details`.
5. **Middleware**: request ID (done), CORS, security headers, body limit, auth.

Mount each real router in `src/index.ts` **above** the `api.all('/*',
notImplemented)` catch-all. When that catch-all stops being reachable, Phase 1
is done.

**Gate:** the conformance suite passes against this service —
`./scripts/conformance.sh typescript`.

Search the tree for `TODO(Phase` to find every marked extension point.
