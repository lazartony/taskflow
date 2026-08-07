// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY — see lib/config.js for why. Closed-loop generators
// under-report tail latency via coordinated omission.
// ─────────────────────────────────────────────────────────────────────────────
//
// Shared response validation and the custom metrics every scenario reports.
//
// The envelope shape asserted here is normative (docs/openapi.yaml): every
// response, success or failure, is {success, data|error, meta{requestId,
// timestamp, traceId}}. Validating it in the load test is cheap and catches the
// classic "the benchmark was measuring a 404 page" mistake.

import { check } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';
import { bool } from './config.js';

// ── Custom metrics ───────────────────────────────────────────────────────────
// One Trend per endpoint so the report can show which operation moved, rather
// than a single blended number in which a 10x regression on DELETE is invisible
// behind 70% of traffic on LIST.
export const errorRate = new Rate('taskflow_errors');
export const notImplemented = new Counter('taskflow_not_implemented');
export const envelopeViolations = new Counter('taskflow_envelope_violations');
export const rateLimited = new Counter('taskflow_rate_limited'); // 429s
export const shed = new Counter('taskflow_load_shed'); // 503s — deliberate shedding

export const trends = {
  list: new Trend('taskflow_list_latency', true),
  get: new Trend('taskflow_get_latency', true),
  create: new Trend('taskflow_create_latency', true),
  update: new Trend('taskflow_update_latency', true),
  del: new Trend('taskflow_delete_latency', true),
  auth: new Trend('taskflow_auth_latency', true),
  health: new Trend('taskflow_health_latency', true),
};

/** Abort the whole test the first time a 501 is seen, unless disabled. */
const ABORT_ON_501 = bool('ABORT_ON_501', true);
let aborted = false;

export const NOT_IMPLEMENTED_MESSAGE =
  'service returns 501 — implement Phase 1 first ' +
  '(the /tasks and /auth routes are still the NOT_IMPLEMENTED catch-all; ' +
  'see docs/learning-roadmap.md Phase 1). Re-run with ABORT_ON_501=0 to ' +
  'measure the 501 path anyway.';

/** True if the response is the skeleton's NOT_IMPLEMENTED placeholder. */
export function isNotImplemented(res) {
  if (res.status !== 501) return false;
  return true;
}

function parseBody(res) {
  try {
    return res.json();
  } catch (_e) {
    return null;
  }
}

/**
 * Validate a response and record its latency.
 *
 * @param {object} res      k6 http response
 * @param {object} opts
 * @param {string} opts.name      tag name, e.g. 'GET /tasks'
 * @param {number[]} opts.expect  acceptable status codes (default [200])
 * @param {Trend} [opts.trend]    endpoint trend to record into
 * @param {boolean} [opts.envelope=true] assert the response envelope
 * @returns {boolean} whether the response counted as a success
 */
export function validate(res, opts) {
  const name = opts.name;
  const expect = opts.expect || [200];
  const wantEnvelope = opts.envelope !== false;

  if (opts.trend) opts.trend.add(res.timings.duration);

  if (res.status === 501) {
    notImplemented.add(1, { endpoint: name });
    errorRate.add(true, { endpoint: name });
    if (ABORT_ON_501 && !aborted) {
      aborted = true;
      exec.test.abort(`${name}: ${NOT_IMPLEMENTED_MESSAGE}`);
    }
    return false;
  }

  if (res.status === 429) rateLimited.add(1, { endpoint: name });
  if (res.status === 503) shed.add(1, { endpoint: name });

  const statusOk = expect.indexOf(res.status) !== -1;
  let envelopeOk = true;

  if (wantEnvelope) {
    const body = parseBody(res);
    envelopeOk =
      body !== null &&
      typeof body === 'object' &&
      typeof body.success === 'boolean' &&
      body.meta !== undefined &&
      body.meta !== null &&
      typeof body.meta.requestId === 'string' &&
      typeof body.meta.timestamp === 'string' &&
      typeof body.meta.traceId === 'string' &&
      // A >=400 status must never carry success:true, and vice versa.
      body.success === (res.status < 400);
    if (!envelopeOk) envelopeViolations.add(1, { endpoint: name });
  }

  const ok = statusOk && envelopeOk;

  check(res, {
    [`${name}: status ${expect.join('|')}`]: () => statusOk,
    [`${name}: envelope well-formed`]: () => envelopeOk,
  });

  // errorRate is the NFR1 error-budget metric. A 429 is a *correct* response
  // from a rate limiter, but it is still a request the client did not get
  // served — count it, and turn RATE_LIMIT_ENABLED=false off for benchmarks.
  errorRate.add(!ok, { endpoint: name });
  return ok;
}

/** Validate a list response and return the task IDs it contained. */
export function validateList(res, name) {
  const ok = validate(res, { name, expect: [200], trend: trends.list });
  if (!ok) return [];
  const body = parseBody(res);
  if (!body || !Array.isArray(body.data)) return [];
  const paginationOk =
    body.pagination !== undefined &&
    typeof body.pagination.page === 'number' &&
    typeof body.pagination.totalItems === 'number';
  check(res, { [`${name}: pagination present`]: () => paginationOk });
  if (!paginationOk) envelopeViolations.add(1, { endpoint: name });
  return body.data.map((t) => t && t.id).filter((id) => typeof id === 'string');
}

/** Extract data.task.id from a create/update response, or null. */
export function taskIdFrom(res) {
  const body = parseBody(res);
  if (!body || !body.data || !body.data.task) return null;
  return body.data.task.id || null;
}

export { parseBody };
