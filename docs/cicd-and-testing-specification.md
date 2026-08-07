# TaskFlow — CI/CD & Testing Specification

Testing strategy, conformance verification across five implementations, load testing, and the delivery pipeline.
Companion to `requirements-specification.md` and `resilience-and-security-specification.md`.

> **Version note.** Tool versions verified **August 2026**.

---

## 1. The Problem This Solves

You are building the same API five times. That creates one opportunity and one hazard.

**The opportunity:** you have a single, unambiguous definition of correct behaviour, and five independent attempts at it. Any disagreement between implementations is a bug in at least one of them, found automatically. Most projects never get this.

**The hazard:** five test suites written in five frameworks that each test what their author remembered to test. The Go suite checks that `dueDate` in the past returns 400. The Python suite doesn't. Six weeks later they behave differently and nobody knows which is right.

The resolution is a strict separation:

| Layer | Written in | Runs against | Answers |
|---|---|---|---|
| **Unit + integration tests** | Each language, idiomatically | That implementation only | "Is this code correct on its own terms?" |
| **Conformance suite** | Once, language-neutral | All five, identically | "Do all five behave the same?" |
| **Load tests** | Once, language-neutral | All five, identically | "How do they compare under load?" |

Constraint C5 in your requirements — "API response formats must be identical across all implementations" — is unenforceable as prose. The conformance suite is what turns it into a build failure.

---

## 2. Requirements

### TST1: Per-Implementation Testing

| ID | Requirement | Priority |
|----|-------------|----------|
| TST1.1 | Each implementation has unit tests for services, validators and domain logic | High |
| TST1.2 | Integration tests run against **real** Postgres, Valkey and Kafka via Testcontainers | High |
| TST1.3 | Line coverage ≥ 70%; branch coverage on auth and validation ≥ 90% | Medium |
| TST1.4 | Tests are hermetic — no shared state, runnable in any order, parallel-safe | High |
| TST1.5 | Each test creates its own isolated data; no reliance on seed data | High |
| TST1.6 | The full per-language suite completes in under 5 minutes | Medium |

### TST2: Cross-Implementation Conformance

| ID | Requirement | Priority |
|----|-------------|----------|
| TST2.1 | A single OpenAPI 3.1 document is the normative contract | High |
| TST2.2 | All five implementations are verified against it by the same tooling | High |
| TST2.3 | The conformance suite covers every endpoint, error code and validation rule | High |
| TST2.4 | Property-based fuzzing derived from the schema runs against all five | Medium |
| TST2.5 | Byte-level response-shape comparison across all five for identical requests | High |
| TST2.6 | Breaking changes to the OpenAPI document fail CI | Medium |

### TST3: Load & Performance

| ID | Requirement | Priority |
|----|-------------|----------|
| TST3.1 | Load tests use an **open-loop / constant-arrival-rate** model | High |
| TST3.2 | All five are tested with identical scenarios on identical hardware | High |
| TST3.3 | Results record p50/p95/p99, throughput, error rate, CPU, RSS | High |
| TST3.4 | A soak test (1h) detects memory leaks and connection leaks | Medium |
| TST3.5 | CI fails on a p95 regression > 20% versus the recorded baseline | Medium |

### CD1: Pipeline

| ID | Requirement | Priority |
|----|-------------|----------|
| CD1.1 | Every PR runs lint, unit, integration and conformance for affected languages | High |
| CD1.2 | Only changed languages run on a PR; `main` runs all five | Medium |
| CD1.3 | All third-party actions pinned by commit SHA | High |
| CD1.4 | Images built for `linux/amd64` and `linux/arm64` | Medium |
| CD1.5 | Images scanned, SBOM'd, signed and attested before push | High |
| CD1.6 | Migrations linted for unsafe patterns before merge | High |
| CD1.7 | Deployment is staged: dev → staging → production, with a manual gate on production | Medium |

---

## 3. The Test Pyramid

```
              ╱╲          E2E / conformance    ~50 tests   (once, ×5 targets)
             ╱  ╲         ─────────────────────────────────
            ╱    ╲        Integration          ~40/language (Testcontainers)
           ╱      ╲       ─────────────────────────────────
          ╱        ╲      Unit                ~150/language (pure, in-memory)
         ╱__________╲
```

**What belongs where**

*Unit* — password hashing and verification, JWT generation and validation (including every rejection case in SEC2.3), input validation rules, pagination arithmetic, the GCRA rate-limit calculation, cache key generation, event envelope construction, error mapping. No I/O, no containers, milliseconds.

*Integration* — repository methods against real Postgres (so constraint violations, enum handling and `NOW()` semantics are real), cache behaviour against real Valkey, outbox publish and consume against a real broker, transaction rollback, migration up/down/up.

*Conformance* — everything HTTP-observable: status codes, response envelope shape, error codes, header presence, pagination metadata, auth enforcement, ownership isolation.

**The mocking rule:** mock at the *edge of your system*, not at the edge of your code. A repository test that mocks the database tests nothing — it verifies your mock returns what you told it to. Postgres enum coercion, partial-index behaviour, `TIMESTAMPTZ` rounding, and constraint error codes are precisely where the bugs live, and a mock has none of them. Testcontainers exists so you never have to make that trade.

---

## 4. Testcontainers

The standard for real-dependency testing in all five languages, all actively maintained:

| Language | Package | Version |
|---|---|---|
| Go | `github.com/testcontainers/testcontainers-go` | v0.44.0 |
| Rust | `testcontainers` + `testcontainers-modules` | 0.28.0 / 0.15.0 |
| Python | `testcontainers` | 4.15.0 |
| C# | `Testcontainers` | 4.13.0 |
| TypeScript | `testcontainers` | 12.1.0 |

**Pattern: one container per package/suite, one schema or database per test.**

```
Suite setup (once):
  start postgres:17-alpine
  start valkey:9.1-alpine
  run migrations

Per test:
  BEGIN; ... ; ROLLBACK          ← fastest, but can't test commit semantics
  or CREATE SCHEMA test_{uuid}   ← full isolation including commits
```

Starting a container per *test* is the mistake that makes people abandon Testcontainers — 200 tests × 3s startup is ten minutes. Container per suite plus schema-per-test keeps the whole integration run under a minute.

Enable **reuse** locally so the container survives between runs (`.testcontainers.properties`: `testcontainers.reuse.enable=true`), and disable it in CI where every run must be clean.

---

## 5. The Conformance Suite

This is the highest-value component in the entire testing setup, and it does not exist in a single-language project.

### 5.1 OpenAPI as the source of truth

`docs/openapi.yaml` — OpenAPI 3.1, hand-written from `api-specification.md`, committed, and normative. Every implementation is measured against it; no implementation defines it.

Generate it once, then treat it like schema: changes are reviewed, versioned and diffed.

### 5.2 Schemathesis — property-based conformance

**Schemathesis** (`schemathesis` v4.24.3, Python) generates test cases directly from the OpenAPI schema and runs them against a live server. It is language-agnostic — it needs only a base URL — which makes it exactly right for "five servers, one spec."

```bash
for port in 8001 8002 8003 8004 8005; do
  schemathesis run docs/openapi.yaml \
    --url "http://localhost:${port}" \
    --checks all \
    --header "Authorization: Bearer ${TOKEN}" \
    --max-examples 200 \
    --report junit \
    --report-junit-path "reports/conformance-${port}.xml"
done
```

`--checks all` enforces: every response status is documented, every response body validates against its schema, `Content-Type` matches, no 500s on schema-valid input, and no server errors on any generated input.

What makes this worth more than hand-written tests: it generates inputs you would not think to write. Unicode in `displayName`, a `pageSize` of 2³¹, an empty-string `title` that passes `minLength: 1` in one framework and not another, a `dueDate` at exactly `NOW()`. Every such disagreement between five implementations is a real ambiguity in your spec.

> **Not Pact.** Pact is consumer-driven contract testing, built for asymmetric service pairs evolving independently. You have five interchangeable servers and one shared spec — different problem, wrong tool. And **not Dredd**: its last npm publish was November 2021.

### 5.3 Hand-written behavioural conformance

Schemathesis verifies *shape*. It cannot verify *semantics* — that a 429 arrives after exactly 100 requests, or that user B gets a 404 on user A's task. Those need explicit tests, written once and parameterised over all five base URLs.

`tests/conformance/` (Python + pytest, chosen because Schemathesis is already Python):

```python
BASE_URLS = {
    "go":         "http://localhost:8001",
    "rust":       "http://localhost:8002",
    "python":     "http://localhost:8003",
    "csharp":     "http://localhost:8004",
    "typescript": "http://localhost:8005",
}

@pytest.fixture(params=BASE_URLS.items(), ids=lambda p: p[0])
def api(request):
    name, url = request.param
    return ApiClient(url, impl=name)
```

Every test then runs five times automatically, and pytest reports which implementation failed.

**Required conformance cases:**

*Auth* — register success shape; duplicate email → 409 `CONFLICT`; weak password → 400 `VALIDATION_ERROR`; login success; wrong password → 401 `INVALID_CREDENTIALS`; unknown email → **identical** response to wrong password; missing token → 401 `UNAUTHORIZED`; malformed token → 401; expired token → 401; `alg: none` → 401; refresh rotation issues a new token; reusing a rotated refresh token → 401 and family revoked; logout invalidates the refresh token.

*Tasks* — create with defaults (`status=pending`, `priority=medium`); create with all fields; `title` empty → 400; `title` 201 chars → 400; `description` 5001 chars → 400; `dueDate` in the past → 400; invalid enum → 400; list pagination metadata exactly correct at boundaries (page 1, last page, page beyond the end); every filter combination; every `sortBy`/`sortOrder`; `pageSize` > 100 clamped or rejected — **identically**; get non-existent → 404; get another user's task → **404, not 403**; update partial; update to `completed` sets `completedAt`; delete is soft.

*Attachments* — upload success; > 10 MB → 400; disallowed type → 400; upload to another user's task → 404; list; delete.

*System* — rate limit: the 101st request in 60s → 429 with correct headers and `retryAfter`; `/auth/*` limits independently at 10/min; CORS preflight for allowed and disallowed origins; `/health/live` and `/health/ready` semantics; security headers present.

*Envelope* — every success has `success: true`, `data`, `meta.requestId`, `meta.timestamp`; every error has `success: false`, `error.code`, `error.message`, `meta`; `meta.timestamp` is ISO-8601 with milliseconds and a `Z` suffix; `requestId` matches `^req_[a-zA-Z0-9]+$`.

### 5.4 The differential test

The strongest check available to a project like this, and it takes about 60 lines:

```python
def test_all_implementations_return_identical_shapes(scenario):
    """Same request to all five → structurally identical responses."""
    responses = {name: send(url, scenario) for name, url in BASE_URLS.items()}

    # Status codes must match exactly
    codes = {n: r.status_code for n, r in responses.items()}
    assert len(set(codes.values())) == 1, f"status divergence: {codes}"

    # JSON structure must match, ignoring values that are legitimately unique
    shapes = {n: normalise(r.json()) for n, r in responses.items()}
    reference = shapes["go"]
    for name, shape in shapes.items():
        assert shape == reference, f"{name} diverges from go:\n{diff(reference, shape)}"


def normalise(obj):
    """Strip values that must differ; keep every key and type."""
    VOLATILE = {"id", "requestId", "timestamp", "createdAt", "updatedAt",
                "completedAt", "accessToken", "refreshToken", "url", "userId", "taskId"}
    if isinstance(obj, dict):
        return {k: (type(v).__name__ if k in VOLATILE else normalise(v))
                for k, v in sorted(obj.items())}
    if isinstance(obj, list):
        return [normalise(o) for o in obj[:1]]   # shape of the first element
    return type(obj).__name__
```

Comparing *types and keys* rather than values means the test is about the contract, not the data. In practice it will catch things like: C# serialising `dueDate` as `2026-08-15T00:00:00` while everyone else emits `2026-08-15T00:00:00.000Z`; Go omitting a null field that TypeScript includes; Rust returning `pageSize` as a string. Every one of those is a real client-breaking difference, and none is caught by testing implementations in isolation.

### 5.5 Breaking-change detection

**oasdiff** on every PR touching `docs/openapi.yaml`:

```bash
oasdiff breaking origin/main:docs/openapi.yaml docs/openapi.yaml --fail-on ERR
```

509 distinct change types across OpenAPI 3.0/3.1/3.2. Removing an endpoint, narrowing a type, adding a required request field, or removing an enum value all fail the build. Additive changes pass. This is how the spec stays a contract rather than documentation.

---

## 6. Load Testing

### 6.1 The measurement error that invalidates most benchmarks

**Coordinated omission.** A closed-loop load generator sends a request, waits for the response, then sends the next. When the server stalls for 2 seconds, the generator also stops sending — so the requests that *would have* been slow are never issued. Your latency histogram is missing exactly the samples that describe the stall.

The effect is not marginal. A closed-loop tool can report p99 = 80 ms on a workload whose true p99 is over a second.

The fix is an **open-loop / constant-arrival-rate** model: fire requests on a fixed schedule regardless of whether previous ones have returned. This is what `wrk2` was built to demonstrate, and what k6's `constant-arrival-rate` executor implements.

**Consequence for this project:** `hey`, plain `wrk`, and `ab` are closed-loop only. Your existing `scripts/benchmark.sh` uses `hey -n 10000 -c 100` — replace it, or the five-language comparison it produces will be measuring the load generator rather than the servers.

### 6.2 Tool: k6

**Grafana k6 v1.8.0**, AGPL-3.0. Chosen because:

- Native open-loop executors (`constant-arrival-rate`, `ramping-arrival-rate`)
- Scripted in JavaScript — deliberately *not* one of the five implementation languages, so no ecosystem gets a home-field advantage
- Exports directly to Prometheus, so load-test results land on the same dashboards as service metrics
- Single static binary, trivially containerised for reproducible runs

Alternatives, current: `vegeta` v12.13.0 (Go, fixed-rate, good), `oha` v1.15.0 (Rust, nice TUI), `Locust` v2.46.3 (Python-scripted), `Gatling` 3.13.5 (JVM, heavier). `bombardier` is stale (last release 2023).

### 6.3 Scenarios

`tests/load/scenarios.js`:

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL;
const errorRate  = new Rate('taskflow_errors');
const listLatency = new Trend('taskflow_list_latency', true);

export const options = {
  scenarios: {
    // Baseline: fixed arrival rate, well under capacity.
    steady: {
      executor: 'constant-arrival-rate',
      rate: 500, timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 200, maxVUs: 2000,
      // maxVUs must be generous: under an open-loop model, VUs accumulate
      // when the server slows. Running out of VUs silently reintroduces
      // coordinated omission — the exact thing this executor prevents.
      exec: 'readHeavy',
    },
    // Find the knee: where does p99 leave the floor?
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 100, timeUnit: '1s',
      preAllocatedVUs: 500, maxVUs: 5000,
      stages: [
        { target: 500,  duration: '2m' },
        { target: 1000, duration: '2m' },
        { target: 2000, duration: '2m' },
        { target: 4000, duration: '2m' },
        { target: 0,    duration: '1m' },
      ],
      exec: 'mixed',
      startTime: '6m',
    },
    // Spike: 10× instantly. Tests load shedding, not throughput.
    spike: {
      executor: 'constant-arrival-rate',
      rate: 5000, timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 1000, maxVUs: 10000,
      exec: 'readHeavy',
      startTime: '16m',
    },
  },
  thresholds: {
    // NFR1: p95 < 200ms
    'http_req_duration{scenario:steady}': ['p(95)<200', 'p(99)<500'],
    'taskflow_errors': ['rate<0.01'],
    'http_req_failed':  ['rate<0.01'],
  },
};

export function readHeavy() {
  const res = http.get(`${BASE}/api/v1/tasks?page=1&pageSize=20`, {
    headers: { Authorization: `Bearer ${__ENV.TOKEN}` },
    tags: { name: 'GET /tasks' },
  });
  listLatency.add(res.timings.duration);
  errorRate.add(res.status !== 200);
  check(res, { 'status 200': r => r.status === 200 });
}
```

Traffic mix for `mixed`, roughly matching a real task app: 70% `GET /tasks`, 15% `GET /tasks/:id`, 10% `POST /tasks`, 4% `PUT /tasks/:id`, 1% `DELETE`.

### 6.4 Fair comparison — the rules

Benchmark results are worthless unless the methodology is. Fix all of these:

1. **One service at a time.** Do not run all five simultaneously — they contend for CPU and for the same Postgres.
2. **Same resource limits.** `--cpus=2 --memory=2g` on every container.
3. **Warm up.** Discard the first 60 s. JIT-compiled runtimes (C#, TypeScript) are materially slower cold; not warming up produces a result that says more about JIT than about the code.
4. **Same data.** Restore an identical database snapshot before each run — 10,000 users × 100 tasks.
5. **Load generator off-box**, or at minimum on pinned separate cores. A saturated generator measures itself.
6. **Three runs**, report the median. Report variance too; a high-variance implementation is a finding, not noise to be averaged away.
7. **Same pool sizes and same GC settings** where they are configurable, or state explicitly that they differ and why.
8. **Record what you cannot control** — kernel version, Docker version, host CPU model, whether the host was otherwise idle.

### 6.5 Results

`benchmarks/results/{date}/results.md`:

| Impl | RPS (p95<200ms) | p50 | p95 | p99 | RSS steady | CPU/1k req | Cold start | Image |
|---|---|---|---|---|---|---|---|---|
| Go | | | | | | | | |
| Rust | | | | | | | | |
| Python | | | | | | | | |
| C# | | | | | | | | |
| TypeScript | | | | | | | | |

Report the **maximum arrival rate at which p95 stays under 200 ms**, not raw maximum throughput. Max throughput is easy to inflate by accepting terrible latency, and it is not a number anyone operates a service by.

Interpret honestly. Rust and Go will show lower memory and tighter tails. C# will likely beat expectations on raw throughput. Python and TypeScript will be perfectly adequate at TaskFlow's scale, and the ramp scenario will show you exactly where they stop being adequate — that inflection point is the genuinely interesting output. Note also that a large share of TaskFlow's latency is Postgres, which is the same for all five; the language differences show up in tail latency and memory long before they show up in p50.

### 6.6 Soak test

1 hour at 60% of the knee rate. Watch for a monotonic rise in: RSS, open file descriptors, database connections, goroutines/tasks/threads, event-loop lag.

A leak is invisible in a 5-minute run and takes production down after four days. The soak is the only test that finds it, and running it once a week on `main` is cheap.

---

## 7. CI Pipeline

### 7.1 Workflow structure

```
.github/
├── actions/                    # composite actions: per-language setup
│   ├── setup-go/action.yml
│   ├── setup-rust/action.yml
│   ├── setup-python/action.yml
│   ├── setup-dotnet/action.yml
│   └── setup-node/action.yml
└── workflows/
    ├── ci.yml                  # PR: detect changes → lint/test affected
    ├── conformance.yml         # PR + main: build all, run conformance
    ├── security.yml            # PR + nightly: scan, SBOM, secrets
    ├── release.yml             # tag: build, sign, attest, push
    ├── load-test.yml           # nightly + manual
    └── _reusable-lang.yml      # reusable: one language, lint+test+build
```

Composite actions for **step sequences** (install toolchain, restore cache); reusable workflows for **whole jobs** (they can define `runs-on`, secrets and matrices; composite actions cannot).

### 7.2 Change detection

Running all five languages on a one-line Go change wastes about 12 minutes per PR. Detect and skip:

```yaml
jobs:
  changes:
    runs-on: ubuntu-24.04
    outputs:
      go:     ${{ steps.filter.outputs.go }}
      rust:   ${{ steps.filter.outputs.rust }}
      shared: ${{ steps.filter.outputs.shared }}
    steps:
      - uses: actions/checkout@<sha>   # v7.0.1
      - uses: dorny/paths-filter@<sha>
        id: filter
        with:
          filters: |
            go:     ['go/**']
            rust:   ['rust/**']
            python: ['python/**']
            csharp: ['csharp/**']
            typescript: ['typescript/**']
            shared: ['docs/openapi.yaml', 'migrations/**', 'tests/conformance/**']
```

`shared: true` forces all five — an OpenAPI or migration change affects everyone by definition.

### 7.3 Language matrix

```yaml
  test:
    needs: changes
    strategy:
      fail-fast: false        # you want all five results, not the first failure
      matrix:
        include:
          - lang: go
            enabled: ${{ needs.changes.outputs.go == 'true' || needs.changes.outputs.shared == 'true' }}
          - lang: rust
            enabled: ${{ needs.changes.outputs.rust == 'true' || needs.changes.outputs.shared == 'true' }}
          # … python, csharp, typescript
    uses: ./.github/workflows/_reusable-lang.yml
    with:
      language: ${{ matrix.lang }}
```

Per-language quality gates:

| Language | Format | Lint | Test | Extra |
|---|---|---|---|---|
| Go | `gofmt -l` | `golangci-lint` | `go test -race -cover ./...` | `govulncheck`, `gosec` |
| Rust | `cargo fmt --check` | `cargo clippy -- -D warnings` | `cargo nextest run` | `cargo audit`, `cargo deny` |
| Python | `ruff format --check` | `ruff check`, `mypy --strict` | `pytest --cov` | `bandit`, `pip-audit` |
| C# | `dotnet format --verify-no-changes` | analyzers as errors | `dotnet test --collect:"XPlat Code Coverage"` | `dotnet list package --vulnerable` |
| TypeScript | `prettier --check` | `eslint --max-warnings 0`, `tsc --noEmit` | `vitest run --coverage` | `npm audit`, `eslint-plugin-security` |

`go test -race` is not optional — the race detector finds concurrency bugs that no amount of test-writing will. Run it in CI even though it slows tests roughly 2×.

### 7.4 Conformance job

```yaml
  conformance:
    needs: [changes, test]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - name: Start full stack
        run: |
          docker compose -f docker-compose.yml \
                         -f docker-compose.infra.yml up -d --build --wait
      - name: Wait for readiness
        run: |
          for port in 8001 8002 8003 8004 8005; do
            timeout 120 sh -c "until curl -sf http://localhost:$port/api/v1/health/ready; do sleep 2; done"
          done
      - name: Schemathesis (all five)
        run: ./scripts/conformance.sh
      - name: Differential comparison
        run: pytest tests/conformance/ -v --junitxml=reports/differential.xml
      - name: Breaking-change check
        if: github.event_name == 'pull_request'
        run: oasdiff breaking origin/${{ github.base_ref }}:docs/openapi.yaml docs/openapi.yaml --fail-on ERR
      - if: always()
        run: docker compose logs --no-color > reports/docker-logs.txt
      - uses: actions/upload-artifact@<sha>
        if: always()
        with: { name: conformance-reports, path: reports/ }
```

`--wait` (compose v2) blocks until healthchecks pass — which is why every service in the compose files needs a real healthcheck rather than a `sleep 30`.

### 7.5 Security job

```yaml
  security:
    runs-on: ubuntu-24.04
    permissions: { contents: read, security-events: write }
    steps:
      - uses: actions/checkout@<sha>
        with: { fetch-depth: 0 }       # gitleaks needs history
      - uses: gitleaks/gitleaks-action@<sha>
      - name: Trivy filesystem scan
        uses: aquasecurity/trivy-action@<sha>
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: '1'
          format: sarif
          output: trivy-fs.sarif
      - uses: github/codeql-action/upload-sarif@<sha>
        with: { sarif_file: trivy-fs.sarif }
```

Nightly, additionally: rescan the published images (new CVEs are disclosed against unchanged images every day), regenerate SBOMs, and run OWASP ZAP baseline against the running stack.

### 7.6 ARM64

GitHub-hosted ARM64 runners are GA — public repos since August 2025, private repos since January 2026. Labels: `ubuntu-24.04-arm`, `ubuntu-22.04-arm`, `windows-11-arm`.

```yaml
strategy:
  matrix:
    runner: [ubuntu-24.04, ubuntu-24.04-arm]
runs-on: ${{ matrix.runner }}
```

Native ARM builds are far faster than QEMU emulation for multi-arch images, and they surface genuinely architecture-dependent bugs — unaligned access, differing float behaviour, and the classic: a Rust or Go dependency that silently only builds on x86.

### 7.7 Release

```yaml
  release:
    permissions:
      contents: read
      packages: write
      id-token: write          # OIDC → keyless cosign signing
      attestations: write
    steps:
      - uses: docker/setup-buildx-action@<sha>
      - uses: docker/build-push-action@<sha>
        id: build
        with:
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ghcr.io/${{ github.repository }}/taskflow-${{ matrix.lang }}:${{ github.sha }}
            ghcr.io/${{ github.repository }}/taskflow-${{ matrix.lang }}:latest
          provenance: mode=max
          sbom: true
          cache-from: type=gha
          cache-to: type=gha,mode=max
      - uses: aquasecurity/trivy-action@<sha>
        with: { image-ref: '...@${{ steps.build.outputs.digest }}', severity: CRITICAL, exit-code: '1' }
      - uses: anchore/sbom-action@<sha>
        with: { image: '...@${{ steps.build.outputs.digest }}', format: cyclonedx-json }
      - uses: sigstore/cosign-installer@<sha>
      - run: cosign sign --yes ghcr.io/...@${{ steps.build.outputs.digest }}
      - uses: actions/attest-build-provenance@<sha>
        with:
          subject-name: ghcr.io/${{ github.repository }}/taskflow-${{ matrix.lang }}
          subject-digest: ${{ steps.build.outputs.digest }}
          push-to-registry: true
```

Keyless signing via OIDC means no key to store, rotate or leak — the signature is bound to the workflow identity and recorded in the Rekor transparency log. This combination gets you SLSA Build Level 2 with no extra work.

### 7.8 Pinned action versions (Aug 2026)

| Action | Version |
|---|---|
| `actions/checkout` | v7.0.1 |
| `actions/setup-go` | v7.0.0 |
| `actions/setup-node` | v7.0.0 |
| `actions/setup-python` | v6.2.0 |
| `actions/setup-dotnet` | v6.0.0 |
| `actions/cache` | v6.1.0 |
| `dtolnay/rust-toolchain` | rolling `@stable` — pin the SHA |

**Pin every one of these by 40-character commit SHA with the version in a trailing comment.** A tag is a mutable pointer; the March 2025 `tj-actions/changed-files` compromise worked by force-pushing over existing tags, including major-version tags, across ~23,000 repositories. Renovate and Dependabot both understand SHA pins and will bump them for you, so this costs nothing ongoing.

---

## 8. Database Migrations in CI

### 8.1 One tool, not five

Five ORMs each generating migrations against one shared schema is a guaranteed conflict — EF Core and Prisma will each want to "fix" what the other did.

**Use one language-agnostic, plain-SQL migration tool as the single source of truth.** `golang-migrate` v4.19.1 or `dbmate` v2.34.1 — both are plain `.sql` up/down files with no ORM opinion. Every implementation then connects to the resulting schema and does not own it.

This also has a pedagogical benefit: writing migrations as SQL rather than as ORM DSL means you actually learn what `ALTER TABLE` does and which forms take an `ACCESS EXCLUSIVE` lock.

### 8.2 Linting for unsafe migrations

**Squawk** (Rust, Apache-2.0, 32 rules) — free, established, with a GitHub Action.

> Note: Atlas moved `atlas migrate lint` behind a paid tier in October 2025, so much older guidance recommending it no longer applies to a free stack. **MigrationPilot** (MIT, 77 rules, auto-fix for 12) is a newer, more comprehensive free option with a shorter track record.

```yaml
- uses: sbdchd/squawk-action@<sha>
  with: { pattern: "migrations/*.sql" }
```

Catches the classic production-stoppers:

| Pattern | Why it breaks production |
|---|---|
| `ADD COLUMN NOT NULL` without default | Full table rewrite under `ACCESS EXCLUSIVE` |
| `CREATE INDEX` without `CONCURRENTLY` | Blocks all writes for the duration |
| `ALTER COLUMN TYPE` | Full rewrite + exclusive lock |
| `ADD CONSTRAINT ... CHECK` without `NOT VALID` | Full scan under lock |
| `DROP COLUMN` | Breaks any deployed code still selecting it |
| `RENAME COLUMN` | Breaks old and new code simultaneously — never do this |

### 8.3 Expand-contract

Zero-downtime schema change means **never** having a moment where deployed code and schema disagree. Rename `display_name` → `full_name` as a worked example:

```
Migration 1 (expand)    ADD COLUMN full_name; backfill in batches; trigger keeps both in sync
Deploy A                code writes BOTH columns, reads display_name
Deploy B                code reads full_name, still writes both
Migration 2 (contract)  drop the trigger; DROP COLUMN display_name
```

Four deployments to rename a column. That is the actual cost of zero downtime, and understanding *why* is more valuable than any framework feature: at every intermediate step, both the old and new versions of the application are correct against the schema as it exists.

### 8.4 Migration tests in CI

```
1. Fresh Postgres container
2. Apply all migrations up      → assert success
3. Apply all down               → assert success, schema empty
4. Apply all up again           → assert identical schema (idempotency)
5. Restore a production-shaped dump, apply pending → assert success + timing
6. Squawk lint on every changed file
```

Step 3 is skipped by nearly everyone, which is why `down` migrations are almost universally broken in real repositories — including in the moment you actually need one.

---

## 9. Scripts

Replace the existing `scripts/` with:

```
scripts/
├── dev-up.sh              # full stack, waits for health
├── dev-down.sh            # teardown + volume prune
├── test-lang.sh <lang>    # lint + unit + integration for one language
├── test-all.sh            # all five, parallel
├── conformance.sh         # schemathesis + differential across five
├── benchmark.sh           # k6 against all five, sequential, fair
├── soak.sh                # 1h soak
├── migrate.sh <up|down|status>
├── seed.sh <small|large>  # 10 users / 10k users × 100 tasks
└── lint-migrations.sh     # squawk
```

`scripts/conformance.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

declare -A IMPLS=([go]=8001 [rust]=8002 [python]=8003 [csharp]=8004 [typescript]=8005)
SPEC=docs/openapi.yaml
mkdir -p reports
FAILED=()

for impl in "${!IMPLS[@]}"; do
  port=${IMPLS[$impl]}
  echo "── ${impl} (:${port}) ─────────────────────────────"

  TOKEN=$(curl -sf -X POST "http://localhost:${port}/api/v1/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"conf-$RANDOM@example.com\",\"password\":\"TestPass123!\",\"displayName\":\"Conformance\"}" \
    | jq -r '.data.tokens.accessToken')

  schemathesis run "$SPEC" \
    --url "http://localhost:${port}" \
    --checks all \
    --header "Authorization: Bearer ${TOKEN}" \
    --max-examples 200 \
    --report junit --report-junit-path "reports/schemathesis-${impl}.xml" \
    || FAILED+=("$impl")
done

echo "── differential comparison ──────────────────────"
pytest tests/conformance/ -v --junitxml=reports/differential.xml || FAILED+=("differential")

if (( ${#FAILED[@]} )); then
  echo "FAILED: ${FAILED[*]}"; exit 1
fi
echo "All implementations conform."
```

---

## 10. Deployment

### 10.1 Progression

```
local     docker compose                                       (daily)
   ↓
dev       kind cluster, auto-deploy from main                   (every merge)
   ↓
staging   kind or managed k8s, production-shaped data           (every merge, gated on conformance)
   ↓
prod      manual approval + canary                              (tagged releases)
```

### 10.2 Kubernetes — worth it, but last

Kubernetes is the lowest item on the priority list in the infrastructure spec for a reason: it is high effort and less differentiating than everything above it. Do it in Phase 10, when the application is genuinely finished, and do it to learn deployment concepts rather than to run TaskFlow.

Current versions: Kubernetes stable **v1.36** (three minor versions supported: 1.36/1.35/1.34). Local clusters: **kind v0.32.0** (upstream kubeadm, closest to real k8s, best for CI), k3d v5.9.0 (lighter, k3s-based), minikube v1.38.1.

**kind** is the recommendation — it runs actual upstream Kubernetes, so what you learn transfers.

What to build:

```
k8s/
├── base/                      # kustomize base
│   ├── deployment.yaml        # probes, resources, securityContext, preStop
│   ├── service.yaml
│   ├── hpa.yaml               # scale on RPS, not CPU
│   ├── pdb.yaml               # PodDisruptionBudget
│   └── networkpolicy.yaml     # default-deny egress
└── overlays/{dev,staging,prod}/
```

The parts that actually teach something: **probes wired to the three health endpoints** (liveness → `/health/live`, readiness → `/health/ready`, startup → `/health/startup` — getting this wrong is the cascade from the resilience spec, made concrete); **`preStop` sleep + `terminationGracePeriodSeconds`** matching your shutdown sequence; **resource requests vs limits** and why a CPU limit causes throttling that looks exactly like a slow application; **PodDisruptionBudget**, so a node drain doesn't take all your replicas at once.

### 10.3 GitOps

**Argo CD v3.5.0** — ~50% market share versus Flux's ~11% (Flux lost its primary commercial sponsor when Weaveworks shut down in 2024). Argo's web UI also makes the reconciliation loop visible, which matters when you're learning it.

```
git push → CI builds, signs, pushes image
        → CI updates the image digest in k8s/overlays/dev
        → Argo CD notices the git change and reconciles the cluster
```

The property worth internalising: **git is the desired state; the cluster converges toward it.** `kubectl apply` from CI is a push model where the cluster can drift silently. GitOps means drift is detected and corrected, and every change has a commit.

---

## 11. Verification Checklist

**Tests**
- [ ] Each language: `test-lang.sh` green in < 5 min
- [ ] Integration tests use real containers, not mocks
- [ ] Tests pass when run in a shuffled order (`go test -shuffle=on`, `pytest -p randomly`)
- [ ] Coverage ≥ 70% line, ≥ 90% branch on auth and validation
- [ ] Go tests pass under `-race`

**Conformance**
- [ ] Schemathesis passes against all five with `--checks all`
- [ ] Differential test reports zero shape divergence
- [ ] All five return identical status codes for every error case
- [ ] `oasdiff` fails CI on a deliberately introduced breaking change

**Load**
- [ ] Load tests use an open-loop executor (`constant-arrival-rate`)
- [ ] `maxVUs` is never exhausted during a run (check k6 output — exhaustion silently reintroduces coordinated omission)
- [ ] Three runs; median reported; variance recorded
- [ ] 1h soak shows flat RSS and flat connection count

**CI**
- [ ] PR touching only `go/` runs only the Go jobs
- [ ] PR touching `docs/openapi.yaml` runs all five
- [ ] Every third-party action pinned by SHA (`grep -rn 'uses:.*@v[0-9]' .github/` returns nothing)
- [ ] `permissions:` declared on every workflow
- [ ] Secret scanning blocks a deliberately committed test secret

**Migrations**
- [ ] up → down → up produces an identical schema
- [ ] Squawk blocks `CREATE INDEX` without `CONCURRENTLY`
- [ ] Only one migration tool writes to the schema

**Release**
- [ ] Multi-arch images build for amd64 and arm64
- [ ] Trivy clean of CRITICAL
- [ ] `cosign verify` succeeds on a published image
- [ ] `gh attestation verify` confirms provenance

---

## Sources

- [Schemathesis](https://schemathesis.readthedocs.io/) · [oasdiff](https://www.oasdiff.com/)
- [Testcontainers](https://testcontainers.com/) · [Docker Testcontainers docs](https://docs.docker.com/testcontainers/)
- [Grafana k6 — versioning and stability](https://grafana.com/docs/k6/latest/reference/versioning-and-stability-guarantees/)
- [Coordinated omission explained](https://www.scylladb.com/2021/04/22/on-coordinated-omission/)
- [GitHub Actions — secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [ARM64 runners GA (public)](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/) · [ARM64 in private repos](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/)
- [GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
- [Squawk — Postgres migration linter](https://squawkhq.com/)
- [Kubernetes releases](https://kubernetes.io/releases/) · [Argo CD vs Flux adoption survey](https://thenewstack.io/survey-argocd-leaves-flux-and-other-gitops-platforms-behind/)
