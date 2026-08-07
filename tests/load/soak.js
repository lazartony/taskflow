// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. `constant-arrival-rate`. A closed-loop soak is worse than
// useless: as a leak degrades the service the generator slows down with it, so
// the offered load quietly drops and the graph flattens out exactly when it
// should be showing you the problem.
// ─────────────────────────────────────────────────────────────────────────────
//
// One hour at 60% of the knee rate. Leak detection, not performance testing.
//
// What to watch WHILE this runs (the k6 summary alone will not show a leak —
// a leak looks like a perfectly healthy load test right up until it does not):
//
//   • RSS                    process_runtime_memory_bytes{type="rss"}
//   • open file descriptors  process_open_fds
//   • DB connections         db_client_connection_count / _pending_requests
//   • concurrency            runtime_concurrency_count
//                            (goroutines / tokio tasks / asyncio tasks /
//                             threadpool threads / libuv handles)
//   • event-loop lag         runtime_event_loop_lag_seconds  (Node, Python)
//
// A MONOTONIC rise in any of those over an hour is the finding. Sawtooth is
// normal (that is GC); a floor that keeps climbing is not.
//
// A leak is invisible in a five-minute run and takes production down after four
// days. This is the only test in the suite that finds it. Run it weekly on main.
//
//   KNEE_RATE=1200 k6 run tests/load/soak.js -e BASE_URL=http://localhost:8001
//
// Get KNEE_RATE from the capacity sweep:
//   scripts/benchmark.sh --impl go --scenario capacity

import { SUMMARY_TREND_STATS, num, sizeMaxVUs, sizePreAllocatedVUs, str } from './lib/config.js';
import { bootstrap } from './lib/auth.js';
import { makeSummary } from './lib/summary.js';
import { mixed } from './lib/workload.js';

// The knee is the arrival rate at which p99 leaves the floor. Soaking AT the
// knee measures queueing; soaking WELL UNDER it measures the code, which is
// what a leak hunt wants.
const KNEE_RATE = num('KNEE_RATE', 1000);
const SOAK_FRACTION = num('SOAK_FRACTION', 0.6);
const RATE = Math.max(1, Math.round(KNEE_RATE * SOAK_FRACTION));
const DURATION = str('SOAK_DURATION', '1h');

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: sizePreAllocatedVUs(RATE),
      // Generous by design. Over an hour a slow degradation will grow the VU
      // pool; hitting the ceiling would cap the offered load and hide the very
      // degradation we are looking for.
      maxVUs: sizeMaxVUs(RATE, 2),
      exec: 'soakWorkload',
      gracefulStop: '1m',
    },
  },
  thresholds: {
    // Over an hour these are drift detectors, not pass/fail performance gates.
    // A soak that ends with a worse p99 than it started with is the signal;
    // compare the first and last 10 minutes in Grafana, not this one number.
    'http_req_duration': ['p(95)<200', 'p(99)<1000'],
    'http_req_failed': ['rate<0.01'],
    'taskflow_errors': ['rate<0.01'],
  },
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export function setup() {
  return bootstrap();
}

export function soakWorkload(state) {
  // Mixed traffic on purpose: a pure-read soak will not find a leak in the
  // write path, and write paths (transactions, outbox rows, cache
  // invalidation) are where leaks actually live.
  mixed(state);
}

export const handleSummary = makeSummary('soak');
