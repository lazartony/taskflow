// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY, and here it matters more than anywhere else in the suite.
//
// A cache's whole value proposition is about the TAIL: it removes the slow
// database round-trips, which live in p95 and p99, not in p50. A closed-loop
// generator suffers coordinated omission — when the uncached run stalls, the
// generator stalls with it and never issues the requests that would have
// queued. The uncached configuration therefore looks ARTIFICIALLY GOOD, and the
// measured benefit of caching comes out far smaller than it really is.
//
// Using a closed-loop tool here would not merely add noise; it would bias the
// result in a specific direction, against the thing being measured.
// ─────────────────────────────────────────────────────────────────────────────
//
// The cache A/B workload. Driven by scripts/bench-cache.sh, which runs it TWICE
// against the same service — once with CACHE_ENABLED=false and once with
// CACHE_ENABLED=true — against identical seeded data, after identical warm-ups.
// This script itself knows nothing about which configuration it is measuring;
// that is the point. Identical request stream, one variable changed.
//
// Modes (AB_MODE):
//   steady    — one arrival rate, the single-point comparison
//   ramp      — stepped arrival rates, so the report can show WHERE the two
//               curves diverge. Caching often buys almost nothing at low load
//               and an enormous amount past the knee; a single-point comparison
//               hides that crossover, which is the actual lesson.
//   stampede  — N simultaneous requests at ONE cold key. Counts (via
//               pg_stat_statements, in the shell) how many of them reached the
//               origin. Without a stampede lock: N. With one: 1.
//
//   k6 run tests/load/cache-ab.js -e AB_MODE=ramp -e RATES=100,250,500,1000
//   k6 run tests/load/cache-ab.js -e AB_MODE=stampede -e STAMPEDE_N=500

import {
  SUMMARY_TREND_STATS,
  num,
  numList,
  sizeMaxVUs,
  sizePreAllocatedVUs,
  str,
} from './lib/config.js';
import { bootstrap } from './lib/auth.js';
import { makeSummary } from './lib/summary.js';
import { getTask, listTasksHot } from './lib/workload.js';

const AB_MODE = str('AB_MODE', 'steady');
const RATE = num('RATE', 500);
const DURATION = str('DURATION', '3m');
const RATES = numList('RATES', [100, 250, 500, 1000, 2000, 4000]);
const STEP_DURATION_S = num('STEP_DURATION_S', 45);
const STAMPEDE_N = num('STAMPEDE_N', 500);

// How many distinct list pages the workload touches.
//
// This number decides the experiment's honesty. Set it to 1 and you measure a
// 100%-hit-ratio fantasy. Set it to 10,000 and you measure a cache that never
// hits, which is a fair test of nothing. Real traffic is Zipfian: a small hot
// set serves most requests. 8 pages plus 15% single-task reads over a
// 25-task working set gives a hit ratio in the 80-95% range, which is what a
// well-tuned cache-aside layer actually achieves.
const HOT_PAGES = num('CACHE_HOT_PAGES', 8);

function buildSteady() {
  const thresholds = {
    'http_req_failed': ['rate<0.01'],
    [`http_req_duration{step:${RATE}}`]: ['p(50)<10000', 'p(95)<200', 'p(99)<500'],
    [`http_req_failed{step:${RATE}}`]: ['rate<0.01'],
  };
  return {
    scenarios: {
      ab_steady: {
        executor: 'constant-arrival-rate',
        rate: RATE,
        timeUnit: '1s',
        duration: DURATION,
        preAllocatedVUs: sizePreAllocatedVUs(RATE),
        // Sized for the UNCACHED run, which is the slow one. Both runs must use
        // the same VU budget or the comparison is between two different
        // generators rather than two server configurations.
        maxVUs: sizeMaxVUs(RATE, 2),
        exec: 'readWorkload',
        gracefulStop: '30s',
        tags: { phase: 'ab-steady', step: String(RATE) },
      },
    },
    thresholds,
  };
}

function buildRamp() {
  // Discrete steps, not a continuous ramp: a continuous ramp blends every
  // arrival rate into one histogram, and "p95 across a ramp" is a number with
  // no operational meaning. Steps give you latency AS A FUNCTION OF rate, which
  // is what the divergence chart in the report needs.
  const scenarios = {};
  const thresholds = {};
  let cursor = 0;
  for (const rate of RATES) {
    scenarios[`ab_${rate}`] = {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: `${STEP_DURATION_S}s`,
      preAllocatedVUs: sizePreAllocatedVUs(rate),
      maxVUs: sizeMaxVUs(rate, 2),
      exec: 'readWorkload',
      gracefulStop: '15s',
      startTime: `${cursor}s`,
      tags: { phase: 'ab-ramp', step: String(rate) },
    };
    // These thresholds are not pass/fail gates — they exist to force k6 to
    // materialise the per-step submetrics into handleSummary, where
    // scripts/bench-cache.sh reads the curve out with jq.
    thresholds[`http_req_duration{step:${rate}}`] = ['p(50)<60000', 'p(95)<200', 'p(99)<500'];
    thresholds[`http_req_failed{step:${rate}}`] = ['rate<0.01'];
    cursor += STEP_DURATION_S + 15;
  }
  return { scenarios, thresholds };
}

function buildStampede() {
  // The classic thundering herd: a popular key expires and every in-flight
  // request misses at once, so N requests all go to the database for the same
  // row. The fix is a stampede lock (SET NX): the first miss acquires it and
  // populates the cache, the rest wait briefly and read the fresh value.
  //
  // shared-iterations with vus == iterations starts every VU with one unit of
  // work, so all N requests leave at essentially the same instant. There is
  // still a few-millisecond skew across VU start-up — enough that a very fast
  // origin could serve a few requests before the first SET lands even WITH a
  // lock. Read the resulting origin-query count as "≈1 vs ≈N", not "exactly".
  return {
    scenarios: {
      stampede: {
        executor: 'shared-iterations',
        vus: STAMPEDE_N,
        iterations: STAMPEDE_N,
        maxDuration: '2m',
        exec: 'stampedeWorkload',
        gracefulStop: '30s',
        tags: { phase: 'stampede' },
      },
    },
    thresholds: {
      // No latency gate. Under a stampede WITHOUT a lock, high latency is the
      // expected (and interesting) outcome.
      'http_req_failed': ['rate<0.05'],
    },
  };
}

const built =
  AB_MODE === 'ramp' ? buildRamp() : AB_MODE === 'stampede' ? buildStampede() : buildSteady();

export const options = {
  scenarios: built.scenarios,
  thresholds: built.thresholds,
  summaryTrendStats: SUMMARY_TREND_STATS,
  // Identical connection behaviour in both runs. Toggling keep-alive between
  // the two halves of an A/B would put TCP handshake cost in one column only.
  noConnectionReuse: false,
  dns: { ttl: '5m', select: 'first', policy: 'preferIPv4' },
};

export function setup() {
  return bootstrap();
}

/** 85% hot list pages, 15% single-task reads — the cacheable read path. */
export function readWorkload(state) {
  if (Math.random() < 0.85) {
    listTasksHot(state, HOT_PAGES);
  } else {
    getTask(state);
  }
}

/**
 * Every VU requests THE SAME key. The shell flushes the cache immediately
 * before this scenario starts, so the key is guaranteed cold and every request
 * is a miss at t=0.
 */
export function stampedeWorkload(state) {
  listTasksHot(state, 1); // page=1, pageSize=20 — one key, for everyone
}

export const handleSummary = makeSummary(`cache-ab-${AB_MODE}`);
