# TaskFlow benchmarks — methodology

This directory holds the load-testing and profiling harness and its output. Read
this before you quote a number from it, and definitely before you publish one.

The harness is deliberately opinionated: it **refuses to produce a results
table** when the conditions for a fair comparison are not met. A benchmark whose
methodology is unsound does not give you rough numbers, it gives you confident
wrong ones — and those are much harder to get rid of than no numbers at all.

---

## Contents

```
scripts/
  seed.sh            deterministic fixture generator (SQL, not HTTP)
  benchmark.sh       the five-language comparison, fair or not at all
  bench-cache.sh     the cache A/B: what does Valkey actually buy?
  profile.sh         per-language CPU/heap profiles captured under load
  profile-diff.sh    profile with the cache on and off, diff the frames
  lib/common.sh      shared helpers (colour, k6 launcher, pg, docker, charts)
  lib/node-cpuprofile.mjs   CDP CPU-profile capture for Node

tests/load/
  lib/config.js      env parsing, VU sizing, shared thresholds
  lib/auth.js        setup() bootstrap — token + task ids, once per test
  lib/checks.js      response validation, custom metrics, 501 detection
  lib/workload.js    the individual operations and the traffic profiles
  lib/summary.js     handleSummary → text + raw JSON + distilled JSON
  scenarios.js       steady / ramp / spike / capacity
  smoke.js           30s sanity check — what CI runs on every PR
  soak.js            1h at 60% of the knee — leak detection
  cache-ab.js        the cache A/B workload (steady / ramp / stampede)
  read-heavy.js      85% list, 15% get
  write-heavy.js     45% create, 25% update, 10% delete, 20% list
  mixed.js           70/15/10/4/1 — the realistic mix
  tools/stub-server.mjs   in-memory stand-in for testing the harness itself

benchmarks/results/<timestamp>/   results.md, results.json, cache-ab.md, …
profiles/<timestamp>/             flamegraphs + a guide to reading them
```

---

## 1. Coordinated omission, and why every executor here is open-loop

This is the single most important idea in this directory. If you take one thing
away, take this.

### The failure

A **closed-loop** load generator works like a user: send a request, wait for the
response, send the next one. `hey`, `ab`, plain `wrk`, and k6's own
`constant-vus` executor all work this way.

Now suppose the server stalls for two seconds — a GC pause, a checkpoint, a lock
wait, a connection-pool exhaustion.

A real client population does not stop arriving during those two seconds. If
1,000 requests per second were arriving, 2,000 more requests pile up behind the
stall, and every one of them experiences some part of it. Your true latency
distribution has 2,000 samples in the 0–2000 ms range.

A closed-loop generator with 100 workers issues **100** requests during the
stall — one per worker, each waiting. It records 100 samples of ~2,000 ms and
then carries on. The 2,000 requests that *would have been slow* were never
issued, so they are not in the histogram.

The generator did not measure the stall. It **participated in** it.

This is **coordinated omission** (the term is Gil Tene's). The effect is not
marginal: a closed-loop tool can report p99 = 80 ms on a workload whose true
p99 is over a second. The faster the server normally is, and the rarer and
deeper the stall, the worse the under-reporting — which means the tool is least
accurate exactly where accuracy matters.

### The fix

**Open loop**: fire requests on a fixed schedule regardless of whether previous
ones have returned. This is what `wrk2` was built to demonstrate and what k6's
`constant-arrival-rate` and `ramping-arrival-rate` executors implement.

Under an open-loop model, a stall causes in-flight requests to *accumulate*.
Each of them is measured. The histogram gets the samples that describe the
stall, because the requests were actually sent.

Every executor in `tests/load/` is one of those two. There is a comment saying
so at the top of every file, because the temptation to "just use constant-vus,
it's simpler" is real and the resulting numbers look fine.

### The trap inside the fix: `maxVUs`

Open-loop executors still need VUs to *issue* requests with. When the server
slows, in-flight requests accumulate and so do VUs. If the pool is exhausted, k6
cannot fire on schedule, drops the arrivals it could not issue, and prints:

```
WARN[0042] Insufficient VUs, reached 200 active VUs and cannot initialise more
```

At that moment the generator has silently become closed-loop again and
coordinated omission is back.

**If you see that warning, the run is void.** `lib/config.js` sizes `maxVUs` as
`rate × worst_case_seconds × 4` with a floor of 200. VUs cost a few KB each;
correctness of the tail is worth far more.

### What this costs you

Open-loop measurement is *pessimistic* relative to what a closed-loop tool
reports, and people find that uncomfortable. It is not pessimism, it is the
absence of a bias. If the honest p99 is 1.2 s, you want to know that before your
users do.

---

## 2. The fair-comparison rules

From `docs/cicd-and-testing-specification.md` §6.4. `scripts/benchmark.sh`
enforces the ones it can and records the ones it cannot.

### 1. One service at a time

**Why:** the five implementations share a host and a Postgres. Run them
concurrently and you measure the scheduler and the database's connection
handling, not the code. Worse, whichever one you start first gets a warm page
cache and warm buffer pool.

**Enforced:** `benchmark.sh` stops every other implementation's container before
each run.

### 2. Identical resource limits

**Why:** `--cpus=2 --memory=2g` on every container. Without a limit, a runtime
that happily spawns a thread per core does better on a 32-core host than the
comparison implies, and the result stops transferring to the 2-vCPU instance
you would actually deploy on.

**Enforced:** `verify_identical_limits()` reads `NanoCpus`, `Memory`,
`CpuQuota` and `CpuPeriod` out of `docker inspect` for every running
implementation and **aborts** if they differ. It also fails when all five are
*equally* unlimited — matching each other is not the same as being controlled.

A subtlety worth knowing: `deploy.resources.limits` in `docker-compose.yml` is
honoured by `docker compose up` in Compose v2, but a container you started by
hand with `docker run` gets no limits at all and will silently outperform.

### 3. Warm up, and throw the warm-up away

**Why:** C# and TypeScript are JIT-compiled. For the first tens of seconds they
are executing interpreted or Tier-0 code while the JIT works in the background.
Connection pools have not opened their connections. Postgres has not seen the
query, so there is no cached plan and the buffer cache is cold.

Measuring any of that produces a result that says more about start-up than
about the code.

**Enforced:** 60 s of read-heavy traffic before every measured run, results
discarded. `--quick` reduces it to 10 s and the report says so.

You can see this for yourself: run `scripts/benchmark.sh --impl csharp
--warmup 0` and compare to `--warmup 60`. The difference is not subtle.

### 4. Identical data

**Why:** query plans depend on table statistics, which depend on row counts and
value distributions. A benchmark against 200 rows and one against 1,000,000 rows
are not two data points on the same curve; they are measurements of two
different query plans.

**Enforced:** `scripts/seed.sh` regenerates a **deterministic** fixture before
each run. Every id, title, status, priority and timestamp is derived from the
row index via md5 — no `random()`, no `now()`. Re-seeding produces byte-identical
data, which is equivalent to restoring a snapshot and needs no `pg_dump`
plumbing.

The fixture's distributions are deliberately skewed (40% pending, 25%
in_progress, 30% completed, 5% archived; priorities 25/40/25/10) rather than
uniform. Uniform data makes every filter equally selective, which is the one
thing real data never is.

### 5. Load generator off-box

**Why:** at 4,000 rps k6 is doing real work — TLS, JSON parsing, metric
aggregation. Sharing a host means the service and the generator compete, and at
the top of a sweep some of the "latency" you measure is that competition.

**Not enforceable from a script.** `benchmark.sh` prints a warning and records
it in `results.md`. For publishable numbers:

```
# on the service host
docker compose up -d go-api
# on a second machine
k6 run tests/load/scenarios.js -e BASE_URL=http://<service-host>:8001
```

### 6. Three runs, median **and** variance

**Why:** a single run is an anecdote. But averaging runs together throws away
the more interesting signal.

**A high coefficient of variation is a finding, not noise.** An implementation
whose capacity swings 30% between identical runs has something happening — GC
pauses that sometimes land inside the measurement window, a background
compaction, connection-pool churn, a JIT decision that goes differently. That is
worth investigating even when the median looks good. `results.md` reports median
and CV side by side for exactly this reason.

### 7. Same pool and GC settings

All five inherit `DATABASE_POOL_SIZE=10` and friends from the shared
`x-api-env` anchor in `docker-compose.yml`. Where a runtime setting has no
equivalent in another language (`DOTNET_gcServer=1`,
`NODE_OPTIONS=--max-old-space-size`), the difference is stated rather than
hidden.

### 8. Record what you cannot control

`environment.txt` captures kernel, OS, Docker and Compose versions, CPU model,
core count, total memory, CPU governor, virtualisation, Postgres and Valkey
versions, every container's resource limits — and the host's load average at
capture time, classified as IDLE / LIGHTLY LOADED / BUSY.

If the host was busy, `benchmark.sh` refuses to run unless you set
`BENCHMARK_ALLOW_BUSY_HOST=1`. A benchmark started on a loaded machine is not
comparable with anything, including itself an hour later.

---

## 3. The headline number: rate under SLO, not peak throughput

`results.md` reports **the maximum arrival rate at which p95 stayed under 200 ms
with fewer than 1% errors**.

It does not report maximum throughput. Max throughput is trivially inflated by
accepting terrible latency — push hard enough and any service will "handle"
10,000 rps with a p99 of nine seconds. Nobody operates a service that way, and
the number does not tell you how many replicas to run.

This is why the default scenario is `capacity`: a sweep of fixed arrival rates,
each held for 60 s, each tagged so the summary carries a separate latency
distribution per rate. The highest rate that met both budgets is the answer.

The mechanism is worth knowing if you extend the suite: k6 only computes a
tagged **submetric** if some threshold references it. The scenario files declare
per-step thresholds like `http_req_duration{step:500}` purely to materialise
those submetrics into `handleSummary`. They are not pass/fail gates — at the top
of a sweep they are *supposed* to fail.

---

## 4. Running it

### Prerequisites

- Docker (the services, Postgres, Valkey)
- `jq`
- k6 — **optional**. Every script prefers a local `k6` binary and falls back to
  `grafana/k6:1.8.0` via Docker automatically. To run one by hand without
  installing anything:

  ```
  docker run --rm -i --network host -v "$PWD:/work" -w /work \
    grafana/k6:1.8.0 run tests/load/smoke.js -e BASE_URL=http://localhost:8001
  ```

### The usual sequence

```bash
docker compose up -d postgres migrate
scripts/seed.sh --size large --truncate

scripts/benchmark.sh --impl go --quick        # ~2 min, checks the harness works
scripts/benchmark.sh --impl all --runs 3      # the real thing, hours
scripts/bench-cache.sh --impl go              # what does Valkey buy?
scripts/profile.sh --impl go --duration 30    # where does the time go?
scripts/profile-diff.sh --impl go             # what did the cache remove?
```

### In CI, on every PR

```bash
k6 run tests/load/smoke.js -e BASE_URL=http://localhost:8001
```

30 seconds, 5 rps, touches every CRUD route. It answers "does this still work
under a trickle of real traffic", not "how fast is it". Keep it under a minute:
a slow required check is a check people learn to route around.

### Weekly, on main

```bash
KNEE_RATE=1200 k6 run tests/load/soak.js
```

One hour at 60% of the knee. Watch RSS, open file descriptors, database
connections, goroutine/task/thread counts and event-loop lag. A **monotonic**
rise in any of them is a leak. Sawtooth is just GC.

A leak is invisible in a five-minute run and takes production down after four
days. The soak is the only test in this suite that finds it.

### Testing the harness without any service

The current skeletons answer `501 NOT_IMPLEMENTED` for every `/api/v1` route
except `/health`. To exercise the harness anyway:

```bash
node tests/load/tools/stub-server.mjs --port 8099 &
k6 run tests/load/smoke.js -e BASE_URL=http://localhost:8099

# and to check the 501 detection actually fires:
node tests/load/tools/stub-server.mjs --port 8098 --mode 501 &
k6 run tests/load/smoke.js -e BASE_URL=http://localhost:8098   # exits 107
```

The stub is a stand-in for testing the *harness*, never a benchmark target. Any
number measured against it describes Node's HTTP stack and nothing else.

### Exporting to Prometheus

```bash
export K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write
scripts/benchmark.sh --impl go
```

Every script adds `--out experimental-prometheus-rw` when that variable is set,
so load-test metrics land on the same Prometheus as the service metrics. **A
load-test p95 and a server-side p95 that disagree is itself a finding** — the
gap is queueing that happens before the server starts its timer, which is
exactly the kind of latency a server-side histogram cannot see.

---

## 5. Reading the output

### `results.md`

| column | means |
|---|---|
| RPS (p95<200ms) | the headline: highest sustained arrival rate meeting both budgets |
| ±CV | coefficient of variation of that figure across runs. **>15% is a finding.** |
| p50 / p95 / p99 | latency at that arrival rate, not blended across the sweep |
| RSS steady | median resident memory sampled every 2 s during the run |
| CPU/1k req | median container CPU% during the run |
| Cold start | `docker start` → first 200 on `/health/ready` |
| Image | compressed-on-disk image size |

Each implementation also gets an ASCII chart of p95 against arrival rate. **The
knee is where the bars stop being flat.** Below it the service is idle-ish and
latency is dominated by Postgres; above it requests are queueing and every extra
arrival makes the queue longer. The knee is a far more useful number than any
single p95.

### `cache-ab.md`

Three measurements, in increasing order of persuasiveness:

1. **latency** — "p95 dropped 40%". Invites an argument about noise.
2. **throughput** — "capacity tripled". Better, but depends on the load shape.
3. **database queries** — "the database served 87% fewer queries". This is the
   one. It is a count rather than a statistic, it is measured on the database
   (`pg_stat_statements`, reset immediately before each run) rather than on the
   client, and it maps directly onto capacity you did not have to buy.

Plus two things a single-point comparison cannot show:

- **the divergence chart** — caching often buys almost nothing at low load and
  an enormous amount past the knee. Where the two curves separate is the real
  lesson. Both charts are drawn on a **shared scale**; independently auto-scaled
  comparison charts are a lie.
- **the stampede** — N simultaneous requests at one cold key. Without a
  stampede lock all N reach the origin; with one (`SET key NX`), about one does.
  That is a different mechanism from "the cache is warm" and needs its own
  demonstration.

If the service does not implement caching yet, the report says so plainly
instead of presenting "0% improvement" as a finding. That is not a measurement
of a cache; it is the absence of one.

### `profiles/<ts>/README.md`

How to read a flamegraph (**wide = time spent, not depth**) and what to look for
in each of the five languages. Generated fresh with every capture.

---

## 6. What this data does **not** support

This section exists because benchmark numbers get quoted long after the caveats
are forgotten.

### "Rust is faster than Python"

The benchmark does not show this, and a 500 rps CRUD workload could not show it.

At these rates the overwhelming majority of each request's wall-clock time is
spent in **Postgres** — parsing, planning, executing, returning rows over a
socket. That is the *same database, same schema, same query, same indexes* for
all five implementations. If p50 is 12 ms and 9 ms of it is the database, the
language is competing for the remaining 3 ms, and the ranking of that 3 ms tells
you nothing about how these languages perform on work that is actually
CPU-bound.

What the comparison *does* show, honestly:

- **tail latency** — where GC pauses and runtime scheduling live. This is a real
  difference and it shows up long before p50 does.
- **memory** — RSS varies by an order of magnitude across the five and is
  directly a hosting cost.
- **the knee** — the arrival rate at which each stops being adequate. This is
  the genuinely interesting output. Python and TypeScript are perfectly
  adequate at TaskFlow's scale; the ramp shows you exactly where they stop being
  so, and that inflection point is a decision-making number in a way that "p50
  is 1.4 ms lower" is not.
- **cold start** — matters for autoscaling and for scale-to-zero.

### "Implementation X can serve N requests per second"

It served N on **this hardware**, with **this dataset size**, with
`DATABASE_POOL_SIZE=10`, with the load generator on the same box, at this
request mix, with these container limits. Change any one and N changes. The
number is a comparison between the five under fixed conditions, not a capacity
model.

### "The cache made the service 3x faster"

It made *this read-heavy workload with this hot-set size* faster. The hot set
was **chosen** (`--hot-pages 8`), not discovered. Point the workload at a single
page and the cache looks perfect; point it at ten thousand and it looks useless.
The chosen number is meant to resemble the Zipfian shape of real traffic, but it
remains an assumption, and it is stated in every report for that reason.

Caching also helps **reads only**. Writes are unaffected at best and slightly
slower at worst, because every write must also invalidate. And a cache trades
**staleness** for latency — `CACHE_TTL_TASK_LIST=60` means a list can be a
minute out of date. Nothing here measures the cost of that; it is a product
decision, not a performance one.

### "p99 is X"

p99 from a five-minute run at a fixed rate is p99 *of that run*. The events that
dominate real p99 — a checkpoint, a failover, a noisy neighbour, a cache
eviction storm, a deploy — mostly do not happen inside five minutes. The soak
test exists partly to widen that window, and it is still not production.

### "Language A uses less CPU per request than language B" (from the profiles)

Do not compare absolute frame widths across two languages' flamegraphs. Sampling
rates differ, symbolisation differs, inlining differs. Compare *shapes* and
*proportions*: "serialisation is 22% here and 4% there" is a real observation;
"this frame is 3 ms wider" is not.

---

## 7. Known limitations of this harness

- **The load generator shares a host with the service.** Rule 5 is recorded, not
  enforced. Above roughly 2,000 rps, treat results as indicative.
- **`docker stats` sampling is coarse** — every 2 s, and Docker's own CPU
  accounting has a sampling window of its own. RSS and CPU figures are
  order-of-magnitude comparisons, not precise measurements. For precise numbers
  use the service's own `process_runtime_memory_bytes` and
  `process_cpu_utilization_ratio`.
- **Cold start is measured from `docker start`**, so it includes container
  runtime setup, not just process start-up. Consistent across the five, but not
  comparable to a bare-metal process launch.
- **The stampede demonstration is approximate.** k6 starts its VUs within a few
  milliseconds of each other rather than at the same instant, so a fast origin
  can serve a handful of requests before the first `SET` lands even when the
  lock works. Read the origin-query count as "≈1 vs ≈N".
- **Re-seeding between runs is slow** for `--size huge` (roughly a minute for
  1M rows, mostly the GIN index). `--no-reseed` trades rule 4 for wall-clock
  time; the report does not currently flag when you have done that.
- **No TLS anywhere.** Real deployments terminate TLS somewhere, and it is not
  free.

---

## Sources

- Gil Tene, *How NOT to Measure Latency* — the coordinated-omission talk.
- `wrk2` — the tool built to demonstrate the fix.
- k6 executors: <https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/>
- Brendan Gregg, *Flame Graphs*: <https://www.brendangregg.com/flamegraphs.html>
- `docs/cicd-and-testing-specification.md` §6 — the requirements this implements.
- `docs/observability-specification.md` §5 — the metric names cross-checked
  against these results.
