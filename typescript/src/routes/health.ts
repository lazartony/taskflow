/**
 * The three health probes (OBS5).
 *
 * Why three endpoints: a single `/health` that checks the database is the most
 * common self-inflicted outage in production. The database blips, every replica
 * fails its *liveness* probe at once, the orchestrator kills them all, and a
 * recoverable dependency blip becomes a total outage. Liveness answers only
 * "is this process wedged". Readiness answers "should I get traffic now".
 */
import { Hono, type Context } from 'hono';
import { failure, success } from '../envelope.js';
import { ping, type Sql } from '../db.js';

/** OBS5.4 — a probe that hits the database on every call is itself a risk. */
const READY_CACHE_TTL_MS = 1000;
/** OBS5.4 — hard ceiling on the dependency check. */
const READY_TIMEOUT_MS = 2000;

interface ReadyCache {
  checkedAt: number;
  healthy: boolean;
}

export function healthRoutes(sql: Sql): Hono {
  const app = new Hono();
  let cache: ReadyCache | null = null;

  async function checkCached(): Promise<boolean> {
    if (cache !== null && Date.now() - cache.checkedAt < READY_CACHE_TTL_MS) {
      return cache.healthy;
    }

    let healthy: boolean;
    try {
      // Promise.race gives the hard timeout: `postgres` has no per-query
      // deadline that also covers waiting for a free pool slot.
      await Promise.race([
        ping(sql),
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error('readiness check timed out')), READY_TIMEOUT_MS),
        ),
      ]);
      healthy = true;
    } catch {
      healthy = false;
    }

    cache = { checkedAt: Date.now(), healthy };
    return healthy;
  }

  // OBS5.1 — liveness. No dependency checks, ever.
  app.get('/live', (c) => success(c, 200, { status: 'alive' }));

  // OBS5.2 — readiness.
  // TODO(Phase 4): add the Valkey PING here.
  // TODO(Phase 6): add the Kafka broker metadata check here.
  const ready = async (c: Context): Promise<Response> => {
    const healthy = await checkCached();
    if (!healthy) {
      // The envelope invariant is absolute: a >=400 status carries
      // success:false and error.code. The detail travels in error.details.
      return failure(c, 503, 'SERVICE_UNAVAILABLE', 'One or more dependencies are unavailable', {
        status: 'not_ready',
        checks: { database: 'down' },
      });
    }
    return success(c, 200, { status: 'ready', checks: { database: 'up' } });
  };

  app.get('/ready', ready);

  // OBS5.5 — `/api/v1/health` stays as an alias of `/health/ready`.
  app.get('/', ready);

  // OBS5.3 — startup. The pool is created and pinged before the server starts
  // listening, so reaching this handler at all means startup succeeded.
  // TODO(Phase 0/12): also assert the expected schema_migrations version, so a
  // replica pointed at an un-migrated database never reports started.
  app.get('/startup', (c) => success(c, 200, { status: 'started' }));

  return app;
}
