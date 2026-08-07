/**
 * PostgreSQL connection pool.
 *
 * `postgres` (porsager) manages a pool internally — `max` is the pool size, and
 * the tagged-template API is parameterised by construction, which removes the
 * most common way of writing an injectable query by hand.
 */
import postgres from 'postgres';
import type { Config } from './config.js';

export type Sql = postgres.Sql;

export function createPool(cfg: Config): Sql {
  return postgres(cfg.databaseUrl, {
    max: cfg.databasePoolSize,
    // Seconds, not milliseconds — the library's unit.
    connect_timeout: Math.ceil(cfg.databaseAcquireTimeoutMs / 1000),
    // The skeleton logs its own lines; leave the driver quiet.
    onnotice: () => {},

    // TODO(Phase 3): idle_timeout and max_lifetime from DATABASE_MAX_LIFETIME,
    //   and a statement_timeout via `connection: { statement_timeout: ... }`.
    // TODO(Phase 2): wrap queries so each one opens a CLIENT span (OBS4.2).
  });
}

/** Cheap liveness query for the readiness probe. */
export async function ping(sql: Sql): Promise<void> {
  await sql`SELECT 1`;
}
