// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. `constant-arrival-rate` / `ramping-arrival-rate`. Closed-loop
// generators suffer coordinated omission: they stop sending when the server
// stalls, so the requests that would have been slow are never issued and the
// reported tail is fiction. See benchmarks/README.md.
// ─────────────────────────────────────────────────────────────────────────────
//
// The realistic mix, per docs/cicd-and-testing-specification.md §6.3:
//
//     70%  GET  /tasks
//     15%  GET  /tasks/:id
//     10%  POST /tasks
//      4%  PUT  /tasks/:id
//      1%  DELETE /tasks/:id
//
// This is the profile the cross-language comparison table is built from,
// because it is the only one whose result generalises to "how would this
// service behave in front of real users".
//
//   k6 run tests/load/mixed.js -e BASE_URL=http://localhost:8001 -e RATE=500
//   MODE=ramp RATES=100,250,500,1000,2000 k6 run tests/load/mixed.js

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
import { mixed } from './lib/workload.js';

const MODE = str('MODE', 'steady'); // steady | ramp
const RATE = num('RATE', 500);
const DURATION = str('DURATION', '5m');
const RATES = numList('RATES', [100, 250, 500, 1000, 2000, 4000]);
const STEP_DURATION_S = num('STEP_DURATION_S', 60);

function buildSteady() {
  return {
    scenarios: {
      mixed: {
        executor: 'constant-arrival-rate',
        rate: RATE,
        timeUnit: '1s',
        duration: DURATION,
        preAllocatedVUs: sizePreAllocatedVUs(RATE),
        maxVUs: sizeMaxVUs(RATE),
        gracefulStop: '30s',
        tags: { phase: 'mixed', step: String(RATE) },
      },
    },
    thresholds: Object.assign({}, NFR1_THRESHOLDS, {
      [`http_req_duration{step:${RATE}}`]: ['p(50)<10000', 'p(95)<200', 'p(99)<500'],
      [`http_req_failed{step:${RATE}}`]: ['rate<0.01'],
    }),
  };
}

function buildRamp() {
  const scenarios = {};
  const thresholds = { 'taskflow_errors': ['rate<0.05'] };
  let cursor = 0;
  for (const rate of RATES) {
    scenarios[`mixed_${rate}`] = {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration: `${STEP_DURATION_S}s`,
      preAllocatedVUs: sizePreAllocatedVUs(rate),
      maxVUs: sizeMaxVUs(rate),
      gracefulStop: '15s',
      startTime: `${cursor}s`,
      tags: { phase: 'mixed', step: String(rate) },
    };
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
  mixed(state);
}

export const handleSummary = makeSummary(`mixed-${MODE}`);
