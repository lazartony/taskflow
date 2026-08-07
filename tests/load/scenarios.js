// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY.
//
// Every executor below is `constant-arrival-rate` or `ramping-arrival-rate`.
// This is not a style preference — it is the difference between a valid
// measurement and an invalid one.
//
// A CLOSED-LOOP generator (k6's `constant-vus`, and everything `hey`, `ab` and
// plain `wrk` can do) sends a request, WAITS for the response, then sends the
// next. When the server stalls for two seconds, the generator stalls too — so
// the requests that would have queued behind the stall are never issued and
// never measured. The resulting histogram is missing precisely the samples that
// describe the outage. This is COORDINATED OMISSION, and it routinely reports
// p99 = 80 ms on a workload whose true p99 is over a second.
//
// Because the whole point of this repository is a five-language comparison, an
// invalid latency measurement would invalidate every conclusion drawn from it.
// Hence: open loop, always.
// ─────────────────────────────────────────────────────────────────────────────
//
// The main suite. Select what runs with SCENARIO=<steady|ramp|spike|capacity|all>.
//
//   k6 run tests/load/scenarios.js -e BASE_URL=http://localhost:8001
//   k6 run tests/load/scenarios.js -e SCENARIO=capacity -e RATES=100,250,500,1000
//
// Prefer scripts/benchmark.sh, which also enforces the fair-comparison rules.

import {
  NFR1_THRESHOLDS,
  SUMMARY_TREND_STATS,
  num,
  numList,
  sizeMaxVUs,
  sizePreAllocatedVUs,
  str,
} from './lib/config.js';
import { bootstrap } from './lib/auth.js';
import { makeSummary } from './lib/summary.js';
import { mixed as mixedProfile, readHeavy as readProfile, writeHeavy as writeProfile } from './lib/workload.js';

const SCENARIO = str('SCENARIO', 'all');

const STEADY_RATE = num('STEADY_RATE', 500);
const STEADY_DURATION = str('STEADY_DURATION', '5m');
const SPIKE_MULTIPLIER = num('SPIKE_MULTIPLIER', 10);
const GRACEFUL_STOP = str('GRACEFUL_STOP', '30s');

// Capacity sweep: the stepped run that answers "what is the maximum arrival
// rate at which p95 stays under 200 ms?" — the only throughput number worth
// quoting. Raw max throughput is trivially inflated by accepting awful latency.
const RATES = numList('RATES', [100, 250, 500, 1000, 2000, 4000]);
const STEP_DURATION_S = num('STEP_DURATION_S', 60);

function secs(spec) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)$/.exec(String(spec).trim());
  if (!m) throw new Error(`cannot parse duration "${spec}"`);
  const v = Number(m[1]);
  return { ms: v / 1000, s: v, m: v * 60, h: v * 3600 }[m[2]];
}

function build() {
  const scenarios = {};
  const thresholds = Object.assign({}, NFR1_THRESHOLDS);
  let cursor = 0; // seconds; scenarios run back-to-back, never concurrently
  const want = (name) => SCENARIO === 'all' || SCENARIO === name;
  const gap = secs(GRACEFUL_STOP);

  // ── steady ────────────────────────────────────────────────────────────────
  // Baseline well under capacity. This is the run whose p95 the NFR1 threshold
  // judges; running it at a rate the service cannot serve would make the
  // threshold a statement about the load generator instead.
  if (want('steady')) {
    scenarios.steady = {
      executor: 'constant-arrival-rate',
      rate: STEADY_RATE,
      timeUnit: '1s',
      duration: STEADY_DURATION,
      // maxVUs is deliberately far above preAllocatedVUs. Under an open-loop
      // model VUs accumulate whenever the server slows: at 500 rps with a
      // 1 s stall you need 500 VUs just to keep issuing on schedule. If the
      // pool runs dry k6 cannot fire on time, drops arrivals, and the
      // generator silently degrades into a CLOSED-LOOP one — reintroducing
      // the exact coordinated omission this executor exists to prevent.
      // Watch the "insufficient VUs" warning; if you see it, the run is void.
      preAllocatedVUs: sizePreAllocatedVUs(STEADY_RATE),
      maxVUs: sizeMaxVUs(STEADY_RATE),
      exec: 'readHeavy',
      gracefulStop: GRACEFUL_STOP,
      startTime: `${cursor}s`,
      tags: { phase: 'steady' },
    };
    thresholds['http_req_duration{phase:steady}'] = ['p(95)<200', 'p(99)<500'];
    thresholds['http_req_failed{phase:steady}'] = ['rate<0.01'];
    cursor += secs(STEADY_DURATION) + gap;
  }

  // ── ramp ──────────────────────────────────────────────────────────────────
  // Find the knee: the arrival rate at which p99 leaves the floor. That
  // inflection point is the genuinely interesting output of this whole suite —
  // far more so than any single-point p95.
  if (want('ramp')) {
    const peak = STEADY_RATE * 8;
    scenarios.ramp = {
      executor: 'ramping-arrival-rate',
      startRate: Math.max(10, Math.round(STEADY_RATE / 5)),
      timeUnit: '1s',
      preAllocatedVUs: sizePreAllocatedVUs(peak),
      maxVUs: sizeMaxVUs(peak),
      stages: [
        { target: STEADY_RATE, duration: '2m' },
        { target: STEADY_RATE * 2, duration: '2m' },
        { target: STEADY_RATE * 4, duration: '2m' },
        { target: peak, duration: '2m' },
        { target: 0, duration: '1m' },
      ],
      exec: 'mixed',
      gracefulStop: GRACEFUL_STOP,
      startTime: `${cursor}s`,
      tags: { phase: 'ramp' },
    };
    // No latency threshold on ramp: it is DESIGNED to exceed capacity. A
    // threshold here would fail every healthy run and teach you to ignore
    // threshold failures, which is worse than having none.
    cursor += 9 * 60 + gap;
  }

  // ── spike ─────────────────────────────────────────────────────────────────
  // 10x instantly. This tests load shedding and admission control, NOT
  // throughput. The correct behaviour is fast 503s (MAX_CONCURRENT_REQUESTS),
  // not a queue that grows without bound; a service that "handles" the spike by
  // buffering it has simply moved the failure to the client's timeout.
  if (want('spike')) {
    const spikeRate = STEADY_RATE * SPIKE_MULTIPLIER;
    scenarios.spike = {
      executor: 'constant-arrival-rate',
      rate: spikeRate,
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: sizePreAllocatedVUs(spikeRate),
      maxVUs: sizeMaxVUs(spikeRate, 2),
      exec: 'readHeavy',
      gracefulStop: GRACEFUL_STOP,
      startTime: `${cursor}s`,
      tags: { phase: 'spike' },
    };
    // Under a 10x spike, shedding is success. We assert only that the service
    // stays *responsive* — a shed request must be refused quickly, not hung.
    thresholds['http_req_duration{phase:spike}'] = ['p(99)<5000'];
    cursor += 30 + gap;
  }

  // ── capacity ──────────────────────────────────────────────────────────────
  // One constant-arrival-rate scenario per step, each tagged with its rate.
  // The per-step THRESHOLDS are what force k6 to materialise the submetrics, so
  // they appear in handleSummary and the shell runners can read the curve out
  // of the JSON. They are not there to pass or fail the run.
  if (want('capacity')) {
    for (const rate of RATES) {
      const key = `cap_${rate}`;
      scenarios[key] = {
        executor: 'constant-arrival-rate',
        rate,
        timeUnit: '1s',
        duration: `${STEP_DURATION_S}s`,
        preAllocatedVUs: sizePreAllocatedVUs(rate),
        maxVUs: sizeMaxVUs(rate),
        exec: 'readHeavy',
        gracefulStop: '15s',
        startTime: `${cursor}s`,
        tags: { phase: 'capacity', step: String(rate) },
      };
      thresholds[`http_req_duration{step:${rate}}`] = ['p(50)<10000', 'p(95)<200', 'p(99)<500'];
      thresholds[`http_req_failed{step:${rate}}`] = ['rate<0.01'];
      thresholds[`taskflow_errors{step:${rate}}`] = ['rate<0.01'];
      cursor += STEP_DURATION_S + 15;
    }
  }

  if (Object.keys(scenarios).length === 0) {
    throw new Error(
      `SCENARIO="${SCENARIO}" matched nothing. Valid: steady, ramp, spike, capacity, all.`,
    );
  }
  return { scenarios, thresholds };
}

const built = build();

export const options = {
  scenarios: built.scenarios,
  thresholds: built.thresholds,
  summaryTrendStats: SUMMARY_TREND_STATS,
  // Discard per-URL tags we do not use; keeps the metric cardinality (and the
  // Prometheus write volume) sane at 4000 rps.
  discardResponseBodies: false, // we validate the envelope, so bodies are needed
  noConnectionReuse: false,
  // A single DNS entry for the whole run — DNS lookups inside the measured
  // path would be measuring the resolver.
  dns: { ttl: '5m', select: 'first', policy: 'preferIPv4' },
};

export function setup() {
  return bootstrap();
}

export function readHeavy(state) {
  readProfile(state);
}

export function mixed(state) {
  mixedProfile(state);
}

export function writeHeavy(state) {
  writeProfile(state);
}

export const handleSummary = makeSummary(SCENARIO);
