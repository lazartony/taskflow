// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. `constant-arrival-rate` / `ramping-arrival-rate`. Closed-loop
// generators suffer coordinated omission: when the server stalls they stop
// sending, so the slow requests are never issued and the tail silently
// disappears from the histogram. See benchmarks/README.md.
// ─────────────────────────────────────────────────────────────────────────────
//
// Read-heavy traffic profile: 85% GET /tasks, 15% GET /tasks/:id.
//
// This is the shape of a task app's real traffic and it is the profile the
// cache A/B benchmark uses, because reads are the only thing a cache-aside
// layer can help with. Writes are, at best, unaffected by caching (and at worst
// slower, because they must also invalidate).
//
//   k6 run tests/load/read-heavy.js -e BASE_URL=http://localhost:8001 -e RATE=500
//   MODE=ramp RATES=100,250,500,1000 k6 run tests/load/read-heavy.js

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
import { readHeavy } from './lib/workload.js';

const MODE = str('MODE', 'steady'); // steady | ramp
const RATE = num('RATE', 500);
const DURATION = str('DURATION', '3m');
const RATES = numList('RATES', [100, 250, 500, 1000, 2000]);
const STEP_DURATION_S = num('STEP_DURATION_S', 60);

function buildSteady() {
  return {
    scenarios: {
      read_heavy: {
        executor: 'constant-arrival-rate',
        rate: RATE,
        timeUnit: '1s',
        duration: DURATION,
        preAllocatedVUs: sizePreAllocatedVUs(RATE),
        // See lib/config.js sizeMaxVUs(): running out of VUs turns this back
        // into a closed-loop generator without any error, only a warning.
        maxVUs: sizeMaxVUs(RATE),
        gracefulStop: '30s',
        tags: { phase: 'read-heavy', step: String(RATE) },
      },
    },
    thresholds: Object.assign({}, NFR1_THRESHOLDS, {
      [`http_req_duration{step:${RATE}}`]: ['p(50)<10000', 'p(95)<200', 'p(99)<500'],
      [`http_req_failed{step:${RATE}}`]: ['rate<0.01'],
    }),
  };
}

function buildRamp() {
  // Stepped rather than continuously ramping: a continuous ramp gives you one
  // blended histogram in which you cannot say which rate produced which
  // latency. Discrete steps let the report plot latency AGAINST arrival rate,
  // which is where the interesting shape lives.
  const scenarios = {};
  const thresholds = { 'taskflow_errors': ['rate<0.05'] };
  let cursor = 0;
  for (const rate of RATES) {
    scenarios[`read_${rate}`] = {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: `${STEP_DURATION_S}s`,
      preAllocatedVUs: sizePreAllocatedVUs(rate),
      maxVUs: sizeMaxVUs(rate),
      gracefulStop: '15s',
      startTime: `${cursor}s`,
      tags: { phase: 'read-heavy', step: String(rate) },
    };
    // Thresholds exist to MATERIALISE the submetric so it lands in the summary.
    thresholds[`http_req_duration{step:${rate}}`] = ['p(50)<10000', 'p(95)<200', 'p(99)<500'];
    thresholds[`http_req_failed{step:${rate}}`] = ['rate<0.01'];
    cursor += STEP_DURATION_S + 15;
  }
  return { scenarios, thresholds };
}

const built = MODE === 'ramp' ? buildRamp() : buildSteady();

export const options = {
  scenarios: built.scenarios,
  thresholds: built.thresholds,
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export function setup() {
  return bootstrap();
}

export default function (state) {
  readHeavy(state);
}

export const handleSummary = makeSummary(`read-heavy-${MODE}`);
