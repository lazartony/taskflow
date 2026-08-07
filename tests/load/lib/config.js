// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY. Every executor in this suite is `constant-arrival-rate` or
// `ramping-arrival-rate`. Closed-loop generators (a VU that waits for the
// response before sending the next request) suffer COORDINATED OMISSION: when
// the server stalls, the generator stalls with it, so the requests that would
// have been slow are never issued and never recorded. The histogram is missing
// exactly the samples that describe the stall. See benchmarks/README.md.
// ─────────────────────────────────────────────────────────────────────────────
//
// Shared configuration for the TaskFlow k6 suite. Everything is driven by
// environment variables so the same script can be pointed at any of the five
// implementations without editing it.

/** Strip trailing slashes so `${BASE_URL}/api/v1` never double-slashes. */
function normalise(u) {
  return String(u || '').replace(/\/+$/, '');
}

export const BASE_URL = normalise(__ENV.BASE_URL || 'http://localhost:8001');
export const API = `${BASE_URL}/api/v1`;

/** Which implementation is under test — used only for tagging/reporting. */
export const IMPL = __ENV.IMPL || 'unknown';

/** Where handleSummary() writes. The runner scripts set this to
 *  benchmarks/results/<timestamp>. Paths are relative to k6's cwd, which the
 *  runner scripts always set to the repository root. */
export const RESULTS_DIR = normalise(__ENV.RESULTS_DIR || 'benchmarks/results/local');

/** Free-form label attached to the distilled metrics file — e.g. `cache-off`. */
export const RUN_LABEL = __ENV.RUN_LABEL || 'default';

/** Read a numeric env var with a default. */
export function num(name, dflt) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return dflt;
  const n = Number(raw);
  if (!Number.isFinite(n)) {
    throw new Error(`env ${name}="${raw}" is not a number`);
  }
  return n;
}

/** Read a boolean env var ("1"/"true"/"yes" are true) with a default. */
export function bool(name, dflt) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return dflt;
  return /^(1|true|yes|on)$/i.test(raw);
}

/** Read a string env var with a default. */
export function str(name, dflt) {
  const raw = __ENV[name];
  return raw === undefined || raw === '' ? dflt : raw;
}

/** Read a comma-separated list of numbers, e.g. RATES="100,250,500". */
export function numList(name, dflt) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return dflt;
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => {
      const n = Number(s);
      if (!Number.isFinite(n)) throw new Error(`env ${name} contains a non-number: "${s}"`);
      return n;
    });
}

// ── maxVUs sizing ────────────────────────────────────────────────────────────
//
// Under an open-loop model VUs are not "concurrent users", they are the pool of
// workers available to *issue* the scheduled requests. When the server slows,
// in-flight requests pile up and VUs accumulate. If the pool runs dry k6 cannot
// issue requests on schedule, drops them, and warns "insufficient VUs" — at
// which point the generator has silently become closed-loop and coordinated
// omission is back. So maxVUs is deliberately generous: it costs a little RAM
// (~a few KB per VU) and buys correctness of the tail.
//
// Rule of thumb: maxVUs >= arrival_rate * worst_tolerable_latency_seconds * 4.
// At 500 rps and a 1 s worst case that is 2000. We use that as the floor.
export function sizeMaxVUs(rate, worstCaseSeconds = 1, safety = 4) {
  return Math.max(200, Math.ceil(rate * worstCaseSeconds * safety));
}

/** preAllocatedVUs: allocated up-front so k6 does not pay allocation cost
 *  mid-test. Roughly the steady-state need; k6 grows towards maxVUs as needed. */
export function sizePreAllocatedVUs(rate, expectedSeconds = 0.05) {
  return Math.max(50, Math.ceil(rate * expectedSeconds * 4));
}

/** Trend statistics reported in every summary. p99 matters more than avg here.
 *  `count` must be listed explicitly or k6 omits it from Trend summaries, and
 *  a percentile without a sample count is not interpretable. */
export const SUMMARY_TREND_STATS = ['count', 'min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'];

/** NFR1 thresholds, shared by every scenario file. */
export const NFR1_THRESHOLDS = {
  'http_req_duration': ['p(95)<200', 'p(99)<500'],
  'taskflow_errors': ['rate<0.01'],
  'http_req_failed': ['rate<0.01'],
};
