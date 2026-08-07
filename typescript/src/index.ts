/**
 * TaskFlow TypeScript API.
 *
 * This is a SKELETON. It starts, connects to Postgres, serves the three health
 * probes for real, and answers 501 NOT_IMPLEMENTED for every other /api/v1
 * route. Everything else is a TODO pointing at the roadmap phase that builds it.
 */
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { loadConfig, type Config } from './config.js';
import { createPool, ping, type Sql } from './db.js';
import { healthRoutes } from './routes/health.js';
import { notImplemented, requestIdMiddleware } from './envelope.js';

/**
 * Structured JSON logs to stdout, matching §4.1 of the observability spec.
 *
 * TODO(Phase 2): replace with a pino instance that also injects trace_id,
 * span_id and trace_flags from the active OTel span.
 */
function createLogger(cfg: Config) {
  const levels: Record<string, number> = { debug: 10, info: 20, warn: 30, error: 40 };
  const threshold = levels[cfg.logLevel] ?? 20;

  const emit = (level: string, message: string, fields: Record<string, unknown> = {}): void => {
    if ((levels[level] ?? 20) < threshold) return;
    process.stdout.write(
      JSON.stringify({
        timestamp: new Date().toISOString(),
        level,
        message,
        service: { name: cfg.serviceName, version: cfg.serviceVersion },
        ...fields,
      }) + '\n',
    );
  };

  return {
    debug: (m: string, f?: Record<string, unknown>) => emit('debug', m, f),
    info: (m: string, f?: Record<string, unknown>) => emit('info', m, f),
    warn: (m: string, f?: Record<string, unknown>) => emit('warn', m, f),
    error: (m: string, f?: Record<string, unknown>) => emit('error', m, f),
  };
}

type Logger = ReturnType<typeof createLogger>;

/** One canonical log line per request. */
function requestLogger(log: Logger) {
  return async (c: Context2, next: () => Promise<void>): Promise<void> => {
    const start = performance.now();
    await next();
    // TODO(Phase 2): add http.route (the Hono route pattern, never the raw
    // path — OBS3.5), trace_id, span_id and user.id.
    log.info('http request completed', {
      http: {
        request: { method: c.req.method },
        route: c.req.routePath,
        response: { status_code: c.res.status },
      },
      url: { path: new URL(c.req.url).pathname },
      duration_ms: Number((performance.now() - start).toFixed(3)),
      request_id: c.get('requestId'),
    });
  };
}

// Minimal structural type for the context fields the logger touches; keeps this
// file free of a Hono generics dance it does not need yet.
type Context2 = {
  req: { method: string; url: string; routePath: string };
  res: { status: number };
  get: (k: string) => unknown;
};

async function main(): Promise<void> {
  const cfg = loadConfig();
  const log = createLogger(cfg);

  // ── Database pool ──────────────────────────────────────────────────────
  const sql: Sql = createPool(cfg);
  await ping(sql); // fail fast: a service that cannot reach its database should not start
  log.info('database pool ready', { max_conns: cfg.databasePoolSize });

  // ── Router ─────────────────────────────────────────────────────────────
  const app = new Hono();
  app.use('*', requestIdMiddleware);
  app.use('*', requestLogger(log));

  // TODO(Phase 1): security headers, CORS, body limit, auth middleware.
  // TODO(Phase 2): OTel instrumentation around the whole app.
  // TODO(Phase 4): valkey-backed rate limiting.
  // TODO(Phase 5): concurrency limiter for load shedding.

  const api = new Hono();
  api.route('/health', healthRoutes(sql));

  // TODO(Phase 1):  api.route('/auth', authRoutes(sql));
  // TODO(Phase 1):  api.route('/tasks', taskRoutes(sql));
  // TODO(Phase 10): api.route('/attachments', attachmentRoutes(sql));

  // Everything else is deliberately 501. Mount real routers ABOVE this line;
  // when it stops being reachable, Phase 1 is done.
  api.all('/*', notImplemented);

  app.route('/api/v1', api);

  // ── Serve ──────────────────────────────────────────────────────────────
  const server = serve({ fetch: app.fetch, port: cfg.port });
  log.info('http server listening', { addr: `:${cfg.port}`, env: cfg.env });

  // ── Graceful shutdown ──────────────────────────────────────────────────
  let shuttingDown = false;

  const shutdown = (signal: string): void => {
    if (shuttingDown) return; // a second SIGTERM must not re-enter this
    shuttingDown = true;
    log.info('shutdown signal received', { signal });

    // The pre-stop delay exists so the load balancer notices we are going away
    // before we stop accepting. Without it, in-flight routing sends requests to
    // a socket that is already closed.
    // TODO(if you deploy this): flip readiness to "not ready" here too, so an
    // orchestrator pulls this instance out of rotation during the delay.
    // Kubernetes itself is off the roadmap on purpose — see "Cut: Kubernetes
    // deployment" in docs/learning-roadmap.md.
    setTimeout(() => {
      const forceExit = setTimeout(() => {
        log.error('graceful shutdown timed out; forcing exit');
        process.exit(1);
      }, cfg.shutdownGracePeriodMs);
      forceExit.unref();

      server.close(() => {
        // TODO(Phase 6): drain the outbox relay and Kafka consumer here, before
        // the pool closes — they hold connections too.
        void sql.end({ timeout: 5 }).then(() => {
          log.info('shutdown complete');
          process.exit(0);
        });
      });
    }, cfg.shutdownPrestopDelayMs);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err: unknown) => {
  process.stdout.write(
    JSON.stringify({
      timestamp: new Date().toISOString(),
      level: 'error',
      message: 'fatal',
      error: { message: err instanceof Error ? err.message : String(err) },
    }) + '\n',
  );
  process.exit(1);
});
