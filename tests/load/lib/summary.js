// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY — see lib/config.js.
// ─────────────────────────────────────────────────────────────────────────────
//
// handleSummary() plumbing.
//
// Every scenario writes THREE things:
//   1. a compact text summary to stdout (no external jslib import, so the suite
//      runs with no network access — jslib.k6.io is fetched at runtime and is a
//      silent failure mode in CI and in air-gapped benchmark hosts),
//   2. the raw k6 summary object as <label>-summary.json,
//   3. a DISTILLED <label>-metrics.json that the shell runners parse with jq.
//
// The distilled file is the contract between the JS and the Bash halves of this
// harness. Its shape is versioned (`schema`) so a change here that breaks
// scripts/benchmark.sh is at least loud about it.
//
// Prometheus remote-write: k6 cannot select an output from inside the script.
// The runner scripts add `--out experimental-prometheus-rw` when
// K6_PROMETHEUS_RW_SERVER_URL is set (see scripts/lib/common.sh). Metrics then
// land on the same Prometheus as the service metrics, which is the whole point
// — a load-test p95 and a server-side p95 that disagree is a finding.

import { IMPL, RESULTS_DIR, RUN_LABEL } from './config.js';

function n(v, d) {
  return typeof v === 'number' && isFinite(v) ? Number(v.toFixed(d === undefined ? 3 : d)) : null;
}

function trendValues(m) {
  if (!m || !m.values) return null;
  const v = m.values;
  return {
    count: n(v.count, 0),
    min: n(v.min),
    avg: n(v.avg),
    med: n(v.med),
    p90: n(v['p(90)']),
    p95: n(v['p(95)']),
    p99: n(v['p(99)']),
    max: n(v.max),
  };
}

/** k6 has used two shapes for threshold results over time. Handle both. */
function thresholdPassed(entry) {
  if (typeof entry === 'boolean') return entry === false ? false : true;
  if (entry && typeof entry === 'object' && 'ok' in entry) return !!entry.ok;
  return true;
}

/** Split `http_req_duration{step:200,foo:bar}` into name + tag map. */
function parseSubmetric(key) {
  const i = key.indexOf('{');
  if (i === -1 || key[key.length - 1] !== '}') return { base: key, tags: null };
  const base = key.slice(0, i);
  const inner = key.slice(i + 1, key.length - 1);
  const tags = {};
  for (const part of inner.split(',')) {
    const j = part.indexOf(':');
    if (j === -1) continue;
    tags[part.slice(0, j).trim()] = part.slice(j + 1).trim();
  }
  return { base, tags };
}

/**
 * Build the distilled metrics object.
 * @param {object} data k6 summary data
 * @param {string} scenarioName
 */
export function distill(data, scenarioName) {
  const metrics = data.metrics || {};
  const durationMs = (data.state && data.state.testRunDurationMs) || 0;

  const dur = metrics['http_req_duration'];
  const failed = metrics['http_req_failed'];
  const reqs = metrics['http_reqs'];
  const iters = metrics['iterations'];
  const checks = metrics['checks'];

  const requests = (reqs && reqs.values && reqs.values.count) || 0;

  const out = {
    schema: 'taskflow.loadtest.v1',
    label: RUN_LABEL,
    impl: IMPL,
    scenario: scenarioName,
    generatedAt: new Date().toISOString(),
    testDurationMs: Math.round(durationMs),
    http: Object.assign(
      { requests, rps: durationMs > 0 ? n((requests / durationMs) * 1000, 2) : null },
      trendValues(dur) || {},
    ),
    httpFailRate: failed && failed.values ? n(failed.values.rate, 5) : null,
    iterations: (iters && iters.values && iters.values.count) || 0,
    checks: checks && checks.values
      ? { rate: n(checks.values.rate, 5), passes: checks.values.passes, fails: checks.values.fails }
      : null,
    dataReceivedBytes: metrics['data_received'] ? metrics['data_received'].values.count : null,
    dataSentBytes: metrics['data_sent'] ? metrics['data_sent'].values.count : null,
    endpoints: {},
    steps: {},
    custom: {},
    thresholds: { passed: [], failed: [] },
    notImplemented: false,
    aborted: false,
  };

  // Per-endpoint custom trends.
  const trendMap = {
    taskflow_list_latency: 'GET /tasks',
    taskflow_get_latency: 'GET /tasks/:id',
    taskflow_create_latency: 'POST /tasks',
    taskflow_update_latency: 'PUT /tasks/:id',
    taskflow_delete_latency: 'DELETE /tasks/:id',
    taskflow_auth_latency: 'GET /auth/me',
    taskflow_health_latency: 'GET /health/live',
  };

  for (const key of Object.keys(metrics)) {
    const m = metrics[key];
    const { base, tags } = parseSubmetric(key);

    // Threshold outcomes (present on both base metrics and submetrics).
    if (m.thresholds) {
      for (const t of Object.keys(m.thresholds)) {
        const rec = `${key}: ${t}`;
        if (thresholdPassed(m.thresholds[t])) out.thresholds.passed.push(rec);
        else out.thresholds.failed.push(rec);
      }
    }

    // Stepped-rate submetrics — the ramp/capacity curve.
    if (tags && tags.step !== undefined) {
      const step = tags.step;
      if (!out.steps[step]) out.steps[step] = { rate: Number(step) };
      if (base === 'http_req_duration') {
        Object.assign(out.steps[step], trendValues(m));
      } else if (base === 'http_req_failed' && m.values) {
        out.steps[step].failRate = n(m.values.rate, 5);
      } else if (base === 'taskflow_errors' && m.values) {
        out.steps[step].errorRate = n(m.values.rate, 5);
      } else if (base === 'http_reqs' && m.values) {
        out.steps[step].requests = m.values.count;
      }
      continue;
    }

    if (trendMap[base] && !tags) {
      out.endpoints[trendMap[base]] = trendValues(m);
      continue;
    }

    if (!tags && base.indexOf('taskflow_') === 0) {
      if (m.type === 'counter') out.custom[base] = m.values.count;
      else if (m.type === 'rate') out.custom[base] = n(m.values.rate, 5);
      else if (m.type === 'gauge') out.custom[base] = n(m.values.value);
    }
  }

  out.notImplemented = (out.custom['taskflow_not_implemented'] || 0) > 0;
  // A test aborted by exec.test.abort() records far fewer iterations than the
  // schedule called for; the runners use this to avoid reporting a partial run
  // as if it were a clean one.
  out.aborted = out.notImplemented;

  // Drop empty containers so the JSON stays readable.
  if (Object.keys(out.steps).length === 0) delete out.steps;
  if (Object.keys(out.endpoints).length === 0) delete out.endpoints;

  return out;
}

function pad(s, w) {
  s = String(s);
  return s.length >= w ? s : s + ' '.repeat(w - s.length);
}
function lpad(s, w) {
  s = String(s);
  return s.length >= w ? s : ' '.repeat(w - s.length) + s;
}
function ms(v) {
  return v === null || v === undefined ? '—' : `${Number(v).toFixed(1)}ms`;
}

/** Compact human-readable summary. Deliberately self-contained (no jslib). */
export function renderText(d) {
  const L = [];
  L.push('');
  L.push('═'.repeat(72));
  L.push(`  TaskFlow load test — ${d.scenario}  [impl=${d.impl}, label=${d.label}]`);
  L.push('═'.repeat(72));

  if (d.notImplemented) {
    L.push('');
    L.push('  !! service returns 501 — implement Phase 1 first.');
    L.push(`     ${d.custom['taskflow_not_implemented']} NOT_IMPLEMENTED responses.`);
    L.push('     The numbers below describe the 501 path, not the API. Ignore them.');
  }

  L.push('');
  L.push(`  duration       ${(d.testDurationMs / 1000).toFixed(1)}s`);
  L.push(`  requests       ${d.http.requests}  (${d.http.rps ?? '—'} rps achieved)`);
  L.push(`  iterations     ${d.iterations}`);
  L.push(`  http failures  ${d.httpFailRate === null ? '—' : (d.httpFailRate * 100).toFixed(3) + '%'}`);
  if (d.checks) {
    L.push(`  checks         ${(d.checks.rate * 100).toFixed(2)}%  (${d.checks.passes} pass / ${d.checks.fails} fail)`);
  }
  L.push('');
  L.push('  latency        ' +
    `p50 ${ms(d.http.med)}   p90 ${ms(d.http.p90)}   p95 ${ms(d.http.p95)}   ` +
    `p99 ${ms(d.http.p99)}   max ${ms(d.http.max)}`);

  if (d.endpoints) {
    L.push('');
    L.push('  ' + pad('endpoint', 20) + lpad('n', 8) + lpad('p50', 10) + lpad('p95', 10) + lpad('p99', 10));
    L.push('  ' + '─'.repeat(58));
    for (const name of Object.keys(d.endpoints)) {
      const e = d.endpoints[name];
      if (!e || !e.count) continue;
      L.push('  ' + pad(name, 20) + lpad(e.count, 8) + lpad(ms(e.med), 10) + lpad(ms(e.p95), 10) + lpad(ms(e.p99), 10));
    }
  }

  if (d.steps) {
    L.push('');
    L.push('  arrival-rate curve (the knee is where p99 leaves the floor)');
    L.push('  ' + pad('rate/s', 10) + lpad('p50', 10) + lpad('p95', 10) + lpad('p99', 10) + lpad('fail', 10));
    L.push('  ' + '─'.repeat(50));
    const keys = Object.keys(d.steps).sort((a, b) => Number(a) - Number(b));
    for (const k of keys) {
      const s = d.steps[k];
      L.push('  ' + pad(k, 10) + lpad(ms(s.med), 10) + lpad(ms(s.p95), 10) + lpad(ms(s.p99), 10) +
        lpad(s.failRate === undefined ? '—' : (s.failRate * 100).toFixed(2) + '%', 10));
    }
  }

  L.push('');
  if (d.thresholds.failed.length === 0) {
    L.push(`  THRESHOLDS: PASS (${d.thresholds.passed.length} checked)`);
  } else {
    L.push(`  THRESHOLDS: FAIL (${d.thresholds.failed.length} of ` +
      `${d.thresholds.failed.length + d.thresholds.passed.length})`);
    for (const f of d.thresholds.failed) L.push(`    ✗ ${f}`);
  }
  L.push('═'.repeat(72));
  L.push('');
  return L.join('\n');
}

/**
 * Factory for handleSummary.
 *
 *   export const handleSummary = makeSummary('steady');
 *
 * Writes into RESULTS_DIR, which the runner scripts create beforehand — k6
 * will not create missing parent directories for you.
 */
export function makeSummary(scenarioName) {
  return function handleSummary(data) {
    const d = distill(data, scenarioName);
    const base = `${RESULTS_DIR}/${RUN_LABEL}-${scenarioName}`;
    const out = {};
    out['stdout'] = renderText(d);
    out[`${base}-metrics.json`] = JSON.stringify(d, null, 2);
    out[`${base}-summary.json`] = JSON.stringify(data, null, 2);
    return out;
  };
}
