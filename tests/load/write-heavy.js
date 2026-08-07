// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. `constant-arrival-rate`. Closed-loop generators suffer
// coordinated omission — when the server stalls they stall too, so the slow
// requests are never issued and never recorded. That matters most exactly here:
// write contention produces long, bursty stalls (lock waits, checkpoint
// flushes) that a closed-loop tool is structurally blind to.
// ─────────────────────────────────────────────────────────────────────────────
//
// Write-heavy traffic profile: 45% POST, 25% PUT, 10% DELETE, 20% GET /tasks.
//
// Not 100% writes — deliberately. A pure-write workload is unrealistic and,
// more importantly, tells you nothing about the failure mode that actually
// happens in production: writes saturating the connection pool and starving
// reads. The 20% of reads is the canary.
//
// This profile MUTATES DATA. It only ever updates or deletes tasks it created
// itself (see lib/workload.js), so the deterministic seeded dataset survives —
// but it does grow the tasks table. Run scripts/seed.sh --truncate before a
// benchmark that must be comparable to a previous one.
//
// Note: caching does not help this profile, and may hurt it slightly (every
// write must also invalidate). That is the expected result, not a bug — it is
// why the cache A/B benchmark uses read-heavy.js instead.
//
//   k6 run tests/load/write-heavy.js -e BASE_URL=http://localhost:8001 -e RATE=200

import {
  SUMMARY_TREND_STATS,
  num,
  sizeMaxVUs,
  sizePreAllocatedVUs,
  str,
} from './lib/config.js';
import { bootstrap } from './lib/auth.js';
import { makeSummary } from './lib/summary.js';
import { writeHeavy } from './lib/workload.js';

// Writes are heavier than reads, so the default rate is lower. Comparing a
// write rate to a read rate is meaningless; compare write rate to write rate.
const RATE = num('RATE', 200);
const DURATION = str('DURATION', '3m');

export const options = {
  scenarios: {
    write_heavy: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      // Writes have a longer service time, so more VUs are in flight at any
      // moment for the same arrival rate. Size for a 2 s worst case rather
      // than 1 s: exhausting the pool silently reintroduces coordinated
      // omission, which is precisely what would hide a lock-wait spike.
      preAllocatedVUs: sizePreAllocatedVUs(RATE, 0.1),
      maxVUs: sizeMaxVUs(RATE, 2),
      gracefulStop: '30s',
      tags: { phase: 'write-heavy', step: String(RATE) },
    },
  },
  thresholds: {
    // Writes get a looser budget than reads. NFR1's 200 ms p95 is stated for
    // the read path; holding a fsync-bound INSERT to the same number would be
    // a threshold nobody can meet and everybody learns to ignore.
    'http_req_duration': ['p(95)<300', 'p(99)<800'],
    'http_req_failed': ['rate<0.01'],
    'taskflow_errors': ['rate<0.01'],
    // The read canary: if reads degrade while writes are hot, the pool is the
    // bottleneck. Watch db_client_connection_pending_requests to confirm.
    'taskflow_list_latency': ['p(95)<200'],
    [`http_req_duration{step:${RATE}}`]: ['p(95)<300'],
    [`http_req_failed{step:${RATE}}`]: ['rate<0.01'],
  },
  summaryTrendStats: SUMMARY_TREND_STATS,
};

export function setup() {
  return bootstrap();
}

export default function (state) {
  writeHeavy(state);
}

export const handleSummary = makeSummary('write-heavy');
