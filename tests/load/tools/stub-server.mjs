#!/usr/bin/env node
// A dependency-free stand-in for a TaskFlow implementation.
//
// It exists so the LOAD HARNESS ITSELF can be tested without Docker, Postgres
// or any of the five services — "does smoke.js actually work" is a different
// question from "is the Go service fast", and conflating them wastes hours.
//
// It is NOT a benchmark target. It holds everything in memory, so any number
// you measure against it describes Node's HTTP stack and nothing else.
//
//   node tests/load/tools/stub-server.mjs --port 8099
//   node tests/load/tools/stub-server.mjs --port 8099 --mode 501
//   node tests/load/tools/stub-server.mjs --port 8099 --latency-ms 5 --cache
//
// Modes:
//   full  (default)  implements auth + tasks well enough for every scenario
//   501              answers 501 NOT_IMPLEMENTED for everything except /health,
//                    exactly like the current skeletons — use it to verify that
//                    the harness detects an unimplemented service and says so
//                    rather than producing a garbage report.

import http from 'node:http';
import { randomUUID } from 'node:crypto';

const argv = process.argv.slice(2);
function arg(name, dflt) {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v === undefined || v.startsWith('--') ? true : v;
}
if (argv.includes('--help') || argv.includes('-h')) {
  console.log(`stub-server.mjs — in-memory TaskFlow stand-in for testing the load harness

  --port <n>        listen port                      (default 8099)
  --mode <m>        full | 501                       (default full)
  --latency-ms <n>  artificial per-request delay     (default 0)
  --cache           simulate a cache: repeated GET /tasks keys are served
                    from memory and skip the artificial "db" delay
  --db-latency-ms   delay applied only on a cache miss (default 8)
  --help`);
  process.exit(0);
}

const PORT = Number(arg('port', 8099));
const MODE = String(arg('mode', 'full'));
const LATENCY_MS = Number(arg('latency-ms', 0));
const CACHE_ON = argv.includes('--cache');
const DB_LATENCY_MS = Number(arg('db-latency-ms', 8));

const users = new Map(); // email -> {id, email, password, displayName, createdAt}
const tokens = new Map(); // token -> userId
const tasks = new Map(); // id -> task
const cache = new Map(); // key -> {body, at}
const CACHE_TTL_MS = 60_000;

let dbQueries = 0;
let cacheHits = 0;
let cacheMisses = 0;

const nowIso = () => new Date().toISOString().replace(/(\.\d{3})\d*Z$/, '$1Z');
const rid = () => 'req_' + randomUUID().replace(/-/g, '').slice(0, 12);
const traceId = () => randomUUID().replace(/-/g, '');
const meta = () => ({ requestId: rid(), timestamp: nowIso(), traceId: traceId() });

function send(res, status, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': buf.length,
  });
  res.end(buf);
}
const ok = (res, status, data, extra) => send(res, status, { success: true, data, ...(extra || {}), meta: meta() });
const err = (res, status, code, message) =>
  send(res, status, { success: false, error: { code, message }, meta: meta() });

const sleep = (ms) => (ms > 0 ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve());

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1_048_576) reject(new Error('too large'));
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

const apiId = (prefix) => `${prefix}_${randomUUID().replace(/-/g, '')}`;

function authUser(req) {
  const h = req.headers['authorization'] || '';
  if (!h.startsWith('Bearer ')) return null;
  const uid = tokens.get(h.slice(7));
  return uid || null;
}

function issue(user) {
  const access = apiId('tok');
  tokens.set(access, user.id);
  return {
    user: {
      id: user.id,
      email: user.email,
      displayName: user.displayName,
      avatarUrl: null,
      createdAt: user.createdAt,
      updatedAt: user.createdAt,
    },
    tokens: { accessToken: access, refreshToken: apiId('rtk'), expiresIn: 900 },
  };
}

function listFor(userId, page, pageSize) {
  const mine = [];
  for (const t of tasks.values()) if (t.userId === userId && !t.deleted) mine.push(t);
  mine.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
  const total = mine.length;
  const start = (page - 1) * pageSize;
  return {
    data: mine.slice(start, start + pageSize).map(strip),
    pagination: {
      page,
      pageSize,
      totalItems: total,
      totalPages: Math.max(1, Math.ceil(total / pageSize)),
      hasNext: start + pageSize < total,
      hasPrev: page > 1,
    },
  };
}

function strip(t) {
  return {
    id: t.id,
    title: t.title,
    description: t.description,
    status: t.status,
    priority: t.priority,
    dueDate: t.dueDate,
    completedAt: t.completedAt,
    createdAt: t.createdAt,
    updatedAt: t.updatedAt,
  };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;

    if (p === '/__stub/stats') {
      return send(res, 200, { dbQueries, cacheHits, cacheMisses, cacheOn: CACHE_ON, mode: MODE });
    }
    if (p === '/__stub/reset') {
      dbQueries = 0; cacheHits = 0; cacheMisses = 0; cache.clear();
      return send(res, 200, { reset: true });
    }

    if (!p.startsWith('/api/v1/')) return err(res, 404, 'NOT_FOUND', 'No such route');
    const route = p.slice('/api/v1'.length);

    if (route.startsWith('/health')) {
      const kind = route === '/health' || route === '/health/ready' ? 'ready' : route.slice(8);
      if (kind === 'live') return ok(res, 200, { status: 'alive' });
      if (kind === 'startup') return ok(res, 200, { status: 'started' });
      return ok(res, 200, { status: 'ready', checks: { database: 'up' } });
    }

    if (MODE === '501') {
      return err(res, 501, 'NOT_IMPLEMENTED',
        'Not implemented yet — see docs/learning-roadmap.md Phase 1');
    }

    await sleep(LATENCY_MS);

    // ── auth ────────────────────────────────────────────────────────────────
    if (route === '/auth/register' && req.method === 'POST') {
      const b = await readBody(req);
      if (!b.email || !b.password || !b.displayName) {
        return err(res, 400, 'VALIDATION_ERROR', 'email, password and displayName are required');
      }
      if (users.has(b.email)) return err(res, 409, 'CONFLICT', 'Email already registered');
      const user = {
        id: apiId('usr'), email: b.email, password: b.password,
        displayName: b.displayName, createdAt: nowIso(),
      };
      users.set(b.email, user);
      return ok(res, 201, issue(user));
    }

    if (route === '/auth/login' && req.method === 'POST') {
      const b = await readBody(req);
      const user = users.get(b.email);
      if (!user || user.password !== b.password) {
        return err(res, 401, 'INVALID_CREDENTIALS', 'Invalid email or password');
      }
      return ok(res, 200, issue(user));
    }

    const uid = authUser(req);
    if (!uid) return err(res, 401, 'UNAUTHORIZED', 'Missing or invalid bearer token');

    if (route === '/auth/me' && req.method === 'GET') {
      for (const u of users.values()) {
        if (u.id === uid) {
          return ok(res, 200, {
            user: {
              id: u.id, email: u.email, displayName: u.displayName, avatarUrl: null,
              createdAt: u.createdAt, updatedAt: u.createdAt,
            },
          });
        }
      }
      return err(res, 404, 'NOT_FOUND', 'User not found');
    }

    // ── tasks ───────────────────────────────────────────────────────────────
    if (route === '/tasks' && req.method === 'GET') {
      const page = Math.max(1, Number(url.searchParams.get('page') || 1));
      const pageSize = Math.min(100, Math.max(1, Number(url.searchParams.get('pageSize') || 20)));
      const key = `${uid}:${page}:${pageSize}`;
      if (CACHE_ON) {
        const hit = cache.get(key);
        if (hit && Date.now() - hit.at < CACHE_TTL_MS) {
          cacheHits++;
          return send(res, 200, { success: true, ...hit.body, meta: meta() });
        }
        cacheMisses++;
      }
      await sleep(DB_LATENCY_MS);
      dbQueries++;
      const body = listFor(uid, page, pageSize);
      if (CACHE_ON) cache.set(key, { body, at: Date.now() });
      return send(res, 200, { success: true, ...body, meta: meta() });
    }

    if (route === '/tasks' && req.method === 'POST') {
      const b = await readBody(req);
      if (!b.title) return err(res, 400, 'VALIDATION_ERROR', 'title is required');
      await sleep(DB_LATENCY_MS);
      dbQueries++;
      const t = {
        id: apiId('tsk'), userId: uid, title: b.title, description: b.description ?? null,
        status: b.status || 'pending', priority: b.priority || 'medium',
        dueDate: b.dueDate ?? null, completedAt: null,
        createdAt: nowIso(), updatedAt: nowIso(), deleted: false,
      };
      tasks.set(t.id, t);
      cache.clear();
      return ok(res, 201, { task: strip(t) });
    }

    const m = /^\/tasks\/([^/]+)$/.exec(route);
    if (m) {
      const t = tasks.get(m[1]);
      if (!t || t.deleted || t.userId !== uid) return err(res, 404, 'NOT_FOUND', 'Task not found');
      if (req.method === 'GET') {
        await sleep(DB_LATENCY_MS);
        dbQueries++;
        return ok(res, 200, { task: strip(t) });
      }
      if (req.method === 'PUT') {
        const b = await readBody(req);
        await sleep(DB_LATENCY_MS);
        dbQueries++;
        for (const f of ['title', 'description', 'status', 'priority', 'dueDate']) {
          if (b[f] !== undefined) t[f] = b[f];
        }
        t.completedAt = t.status === 'completed' ? nowIso() : null;
        t.updatedAt = nowIso();
        cache.clear();
        return ok(res, 200, { task: strip(t) });
      }
      if (req.method === 'DELETE') {
        await sleep(DB_LATENCY_MS);
        dbQueries++;
        t.deleted = true;
        cache.clear();
        return ok(res, 200, { message: 'Task deleted successfully' });
      }
    }

    return err(res, 404, 'NOT_FOUND', 'No such route');
  } catch (e) {
    return err(res, 500, 'INTERNAL_ERROR', String(e && e.message));
  }
});

server.keepAliveTimeout = 65_000;
server.headersTimeout = 70_000;
server.maxRequestsPerSocket = 0;
server.listen(PORT, () => {
  console.log(
    `stub-server listening on http://localhost:${PORT}  ` +
    `mode=${MODE} cache=${CACHE_ON} latency=${LATENCY_MS}ms db=${DB_LATENCY_MS}ms`,
  );
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`\nstub-server stats: db=${dbQueries} hits=${cacheHits} misses=${cacheMisses}`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 500).unref();
  });
}
