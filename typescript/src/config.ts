/**
 * Runtime configuration, read from the environment.
 *
 * Every key here appears in the repository-root `.env.example`. Only the subset
 * the skeleton actually uses is parsed; the rest arrive in later phases.
 */

export interface Config {
  port: number;
  env: string;
  serviceName: string;
  serviceVersion: string;
  logLevel: string;
  databaseUrl: string;
  databasePoolSize: number;
  databaseAcquireTimeoutMs: number;
  shutdownGracePeriodMs: number;
  shutdownPrestopDelayMs: number;

  // TODO(Phase 1): jwtSecret, jwtIssuer, jwtAudience, jwtAccessExpiry,
  //   jwtRefreshExpiry, bcryptCost, corsOrigins, maxBodyBytes.
  // TODO(Phase 4): valkeyUrl, cacheEnabled, rateLimit* keys.
  // TODO(Phase 6): kafkaBrokers, outbox* keys.
  // TODO(Phase 10): s3Endpoint, s3Bucket, s3AccessKey, s3SecretKey.
}

function str(key: string, fallback: string): string {
  const v = process.env[key];
  return v === undefined || v === '' ? fallback : v;
}

function int(key: string, fallback: number): number {
  const v = process.env[key];
  if (v === undefined || v === '') return fallback;
  const n = Number.parseInt(v, 10);
  if (Number.isNaN(n)) throw new Error(`${key} must be an integer, got ${JSON.stringify(v)}`);
  return n;
}

/**
 * Parses a Go-style duration ("30s", "5m", "1500ms") into milliseconds.
 * `.env.example` uses that format for the shutdown keys, so all five services
 * have to understand it.
 */
function durationMs(key: string, fallbackMs: number): number {
  const v = process.env[key];
  if (v === undefined || v === '') return fallbackMs;
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)$/.exec(v.trim());
  if (!m) return fallbackMs;
  const n = Number.parseFloat(m[1]!);
  const unit = { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[m[2] as 'ms' | 's' | 'm' | 'h'];
  return Math.round(n * unit);
}

/** Reads the environment and throws on anything missing or malformed. */
export function loadConfig(): Config {
  const databaseUrl = process.env.DATABASE_URL ?? '';
  if (databaseUrl === '') throw new Error('DATABASE_URL is required');

  return {
    port: int('PORT', 8080),
    env: str('ENV', 'development'),
    serviceName: str('OTEL_SERVICE_NAME', 'taskflow-typescript'),
    serviceVersion: str('OTEL_SERVICE_VERSION', '1.0.0'),
    logLevel: str('LOG_LEVEL', 'info'),
    databaseUrl,
    databasePoolSize: int('DATABASE_POOL_SIZE', 10),
    databaseAcquireTimeoutMs: int('DATABASE_ACQUIRE_TIMEOUT_MS', 2000),
    shutdownGracePeriodMs: durationMs('SHUTDOWN_GRACE_PERIOD', 30_000),
    shutdownPrestopDelayMs: durationMs('SHUTDOWN_PRESTOP_DELAY', 5_000),
  };
}
