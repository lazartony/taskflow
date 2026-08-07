// ─────────────────────────────────────────────────────────────────────────────
// OPEN-LOOP ONLY — see lib/config.js. This module runs in k6's setup() stage,
// which is not part of the measured load; nothing here affects the histogram.
// ─────────────────────────────────────────────────────────────────────────────
//
// Auth bootstrap for the load suite.
//
// k6 runs `setup()` exactly ONCE for the whole test and hands the returned
// value to every VU (it is serialised to JSON and copied in). That is the right
// place to obtain a token: minting one per VU would (a) benchmark bcrypt rather
// than the API and (b) trip the auth rate limiter within seconds.
//
// Three ways to get credentials, in priority order:
//   1. SEED_MANIFEST=<path>  — a manifest written by scripts/seed.sh; log in as
//      a deterministically-seeded user so every run sees the SAME dataset.
//      This is what the benchmark and cache A/B runs use.
//   2. LOGIN_EMAIL / LOGIN_PASSWORD — explicit credentials.
//   3. Register a throwaway user — what smoke.js does by default.

import http from 'k6/http';
import { API, BASE_URL, num, str } from './config.js';
import { NOT_IMPLEMENTED_MESSAGE, notImplemented, parseBody } from './checks.js';

const JSON_HEADERS = { 'Content-Type': 'application/json' };

// open() is only legal in the init context, so the manifest is read at module
// load time, not inside setup().
const MANIFEST_PATH = str('SEED_MANIFEST', '');
const MANIFEST = loadManifest(MANIFEST_PATH);

/**
 * Load the seed manifest written by scripts/seed.sh.
 *
 * k6's open() does NOT resolve relative to the process's working directory. In
 * k6 1.x it resolves relative to the ENTRY SCRIPT's directory (so
 * `tests/load/`), and k6 warns that a future version will change this to the
 * directory of the module that calls it (`tests/load/lib/`). Either way, a
 * repo-root-relative path like `benchmarks/seed-manifest.json` — which is what
 * the runner scripts pass, and what anyone would type — does not resolve.
 *
 * That mattered a lot more than it looks: a silently-unloaded manifest makes
 * the suite fall back to registering a throwaway user, so every benchmark run
 * would quietly measure a DIFFERENT dataset. Fair-comparison rule 4 would be
 * violated with no error anywhere. So: try the plausible prefixes, and if the
 * caller explicitly asked for a manifest and none of them work, FAIL LOUDLY.
 */
function loadManifest(path) {
  if (!path) return null;

  const candidates = path.charAt(0) === '/'
    ? [path]
    : [
        path,             // already relative to the entry script
        '../../' + path,  // entry script in tests/load/ → repo root (k6 1.x)
        '../../../' + path, // module in tests/load/lib/ → repo root (future k6)
        '../' + path,
      ];

  const tried = [];
  for (const c of candidates) {
    try {
      const parsed = JSON.parse(open(c));
      if (parsed && Array.isArray(parsed.users) && parsed.users.length > 0) {
        return parsed;
      }
      tried.push(`${c} (opened, but has no users[])`);
    } catch (e) {
      tried.push(`${c} (${String(e.message || e).slice(0, 60)})`);
    }
  }

  throw new Error(
    `SEED_MANIFEST="${path}" could not be loaded. Tried:\n  ` +
    tried.join('\n  ') +
    '\n\nk6\'s open() is relative to the script directory, not the working ' +
    'directory. Generate the manifest with `scripts/seed.sh`, and pass either a ' +
    'path relative to the repository root (handled above) or an absolute path. ' +
    'Unset SEED_MANIFEST to register a throwaway user instead — but note that ' +
    'then each run uses different data, and runs are not comparable.',
  );
}

/**
 * Human-readable failure text with the URL, so a typo'd port is obvious.
 *
 * Order matters: k6 populates res.error_code for ordinary HTTP error STATUSES
 * too (1000 + status), not only for transport failures. Checking error_code
 * first would report every 501 as "connection failed" — which is exactly the
 * misdiagnosis this harness is supposed to prevent. status === 0 is the real
 * "never got a response" signal.
 */
function describe(res, what) {
  if (res.status === 501) {
    // Record it as a metric as well as throwing, so the distilled summary the
    // shell runners read says "notImplemented" rather than just "crashed".
    notImplemented.add(1, { endpoint: what });
    return `${what}: ${NOT_IMPLEMENTED_MESSAGE}`;
  }
  if (res.status === 0) {
    return `${what}: could not reach ${BASE_URL} (${res.error || 'connection failed'}` +
      `${res.error_code ? `, error_code=${res.error_code}` : ''}). ` +
      'Is the service up? Try: docker compose up -d <impl>-api';
  }
  return `${what}: HTTP ${res.status} — ${String(res.body).slice(0, 300)}`;
}

/**
 * Probe the service before doing anything else, so a dead port produces one
 * clear line instead of thousands of connection errors in the histogram.
 */
export function preflight() {
  const res = http.get(`${API}/health/live`, { tags: { name: 'GET /health/live' } });
  if (res.status !== 200) {
    throw new Error(describe(res, 'preflight GET /api/v1/health/live'));
  }
  return true;
}

/** Tokens out of the AuthSessionResponse envelope, or null. */
function tokensFrom(res) {
  const body = parseBody(res);
  if (!body || !body.data || !body.data.tokens) return null;
  const t = body.data.tokens;
  if (!t.accessToken) return null;
  return {
    accessToken: t.accessToken,
    refreshToken: t.refreshToken || null,
    expiresIn: t.expiresIn || null,
    userId: (body.data.user && body.data.user.id) || null,
  };
}

/** POST /auth/login. Throws with a specific message on failure. */
export function login(email, password) {
  const res = http.post(
    `${API}/auth/login`,
    JSON.stringify({ email, password }),
    { headers: JSON_HEADERS, tags: { name: 'POST /auth/login' } },
  );
  const tokens = tokensFrom(res);
  if (!tokens) throw new Error(describe(res, `login as ${email}`));
  return tokens;
}

/** POST /auth/register. Throws with a specific message on failure. */
export function register(email, password, displayName) {
  const res = http.post(
    `${API}/auth/register`,
    JSON.stringify({ email, password, displayName }),
    { headers: JSON_HEADERS, tags: { name: 'POST /auth/register' } },
  );
  // 409 means the user already exists (a re-run with the same seed) — log in.
  if (res.status === 409) return login(email, password);
  const tokens = tokensFrom(res);
  if (!tokens) throw new Error(describe(res, `register ${email}`));
  return tokens;
}

function authHeaders(token) {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

/** Collect up to `want` task IDs, paging through GET /tasks. */
function collectTaskIds(token, want) {
  const ids = [];
  const pageSize = Math.min(100, Math.max(1, want));
  for (let page = 1; ids.length < want && page <= 50; page++) {
    const res = http.get(`${API}/tasks?page=${page}&pageSize=${pageSize}`, {
      headers: authHeaders(token),
      tags: { name: 'GET /tasks' },
    });
    if (res.status !== 200) {
      if (res.status === 501) throw new Error(describe(res, 'GET /api/v1/tasks'));
      break;
    }
    const body = parseBody(res);
    if (!body || !Array.isArray(body.data) || body.data.length === 0) break;
    for (const t of body.data) if (t && t.id) ids.push(t.id);
    if (!body.pagination || !body.pagination.hasNext) break;
  }
  return ids.slice(0, want);
}

/** Create `n` tasks so read scenarios have something to read. */
function createTasks(token, n) {
  const ids = [];
  const priorities = ['low', 'medium', 'high', 'urgent'];
  const statuses = ['pending', 'in_progress', 'completed'];
  for (let i = 0; i < n; i++) {
    const res = http.post(
      `${API}/tasks`,
      JSON.stringify({
        title: `Load-test seed task ${i}`,
        description: `Created by tests/load/lib/auth.js setup() — index ${i}.`,
        status: statuses[i % statuses.length],
        priority: priorities[i % priorities.length],
      }),
      { headers: authHeaders(token), tags: { name: 'POST /tasks' } },
    );
    if (res.status !== 201) {
      if (res.status === 501) throw new Error(describe(res, 'POST /api/v1/tasks'));
      throw new Error(describe(res, `create setup task ${i}`));
    }
    const body = parseBody(res);
    if (body && body.data && body.data.task && body.data.task.id) ids.push(body.data.task.id);
  }
  return ids;
}

/**
 * The setup() payload every scenario file uses.
 *
 * @returns {{token: string, userId: string|null, email: string,
 *            taskIds: string[], source: string}}
 */
export function bootstrap(opts) {
  const options = opts || {};
  const wantTasks = options.taskIds === undefined ? num('SETUP_TASKS', 25) : options.taskIds;

  preflight();

  let creds;
  let source;

  if (MANIFEST) {
    // Deterministic seeded user. Index chosen by SEED_USER_INDEX so parallel
    // runs can target different users without colliding on the cache key.
    const idx = num('SEED_USER_INDEX', 0) % MANIFEST.users.length;
    const u = MANIFEST.users[idx];
    creds = { email: u.email, password: u.password || MANIFEST.password };
    source = `seed-manifest[${idx}]`;
  } else if (str('LOGIN_EMAIL', '')) {
    creds = { email: str('LOGIN_EMAIL', ''), password: str('LOGIN_PASSWORD', '') };
    source = 'env-credentials';
  } else {
    creds = null;
    source = 'registered';
  }

  let tokens;
  let email;
  if (creds) {
    email = creds.email;
    tokens = login(creds.email, creds.password);
  } else {
    // Unique enough to survive a re-run without a 409, and it is a valid
    // address per the OpenAPI `format: email` constraint.
    email = `loadtest-${Date.now()}-${Math.floor(Math.random() * 1e6)}@taskflow.test`;
    tokens = register(email, 'LoadTest123', 'Load Test');
  }

  let taskIds = collectTaskIds(tokens.accessToken, wantTasks);
  if (taskIds.length === 0 && wantTasks > 0) {
    taskIds = createTasks(tokens.accessToken, wantTasks);
  }

  if (taskIds.length === 0 && wantTasks > 0) {
    throw new Error(
      'setup(): no task IDs available. Seed the database (scripts/seed.sh) or ' +
      'check that POST /api/v1/tasks works.',
    );
  }

  return {
    token: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    userId: tokens.userId,
    email,
    taskIds,
    source,
    baseUrl: BASE_URL,
  };
}

export { authHeaders, JSON_HEADERS };
