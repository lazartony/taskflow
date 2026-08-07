// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. `constant-arrival-rate`, never `constant-vus`. A closed-loop
// generator waits for each response before sending the next, so it never issues
// the requests that would have piled up behind a stall — coordinated omission.
// Even at smoke-test rates we keep the model consistent, because a smoke test
// that measures differently from the benchmark is a smoke test whose numbers
// nobody can compare to anything.
// ─────────────────────────────────────────────────────────────────────────────
//
// 30-second sanity check at a low, safe rate. THIS IS WHAT CI RUNS ON EVERY PR.
//
// Its job is to answer "does the service still work under a trickle of real
// traffic", not "how fast is it". It touches every CRUD route once per
// iteration so a broken endpoint fails the PR that broke it. Keep it under a
// minute; a slow required check is a check people learn to skip.
//
//   k6 run tests/load/smoke.js -e BASE_URL=http://localhost:8001

import { NFR1_THRESHOLDS, SUMMARY_TREND_STATS, num, str } from './lib/config.js';
import { bootstrap } from './lib/auth.js';
import { makeSummary } from './lib/summary.js';
import { smokeAll } from './lib/workload.js';

const RATE = num('SMOKE_RATE', 5);
const DURATION = str('SMOKE_DURATION', '30s');

export const options = {
  scenarios: {
    smoke: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      // One iteration issues six requests, so a VU is busy for ~6x a single
      // request. preAllocated is sized for that; maxVUs is still generous
      // because running out silently reintroduces coordinated omission.
      preAllocatedVUs: Math.max(10, RATE * 4),
      maxVUs: Math.max(100, RATE * 40),
      gracefulStop: '10s',
    },
  },
  thresholds: Object.assign({}, NFR1_THRESHOLDS, {
    // Smoke runs at a rate the service must handle trivially. If p95 is over
    // 200 ms here, something is broken rather than merely loaded.
    'http_req_duration': ['p(95)<200', 'p(99)<1000'],
    'checks': ['rate>0.99'],
  }),
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export function setup() {
  // A handful of tasks is plenty; a smoke test should not spend 20 seconds
  // seeding before it starts.
  return bootstrap({ taskIds: num('SETUP_TASKS', 5) });
}

export default function (state) {
  smokeAll(state);
}

export const handleSummary = makeSummary('smoke');
