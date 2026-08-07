/**
 * The HTTP response envelope and the request-scoped identifiers every
 * TaskFlow response carries.
 *
 * The shape here is normative — the language-neutral conformance suite asserts
 * it across all five implementations. Do not change a field name without
 * changing the other four services too.
 */
import type { Context } from 'hono';
import { randomBytes } from 'node:crypto';

export interface Meta {
  /** Human-quotable support identifier, `^req_[a-zA-Z0-9]+$`. */
  requestId: string;
  /** ISO-8601 with milliseconds and a literal Z suffix. */
  timestamp: string;
  /** 32 lowercase hex — the key into Tempo (OBS4.7). */
  traceId: string;
}

export interface SuccessEnvelope<T> {
  success: true;
  data: T;
  meta: Meta;
}

export interface ErrorEnvelope {
  success: false;
  error: { code: string; message: string; details?: unknown };
  meta: Meta;
}

const ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/** `req_` followed by 12 alphanumeric characters. */
export function newRequestId(): string {
  const bytes = randomBytes(12);
  let out = 'req_';
  for (const b of bytes) out += ALPHABET[b % ALPHABET.length];
  return out;
}

/**
 * 32 lowercase hex characters.
 *
 * TODO(Phase 2): delete this. Once the OpenTelemetry SDK is wired up the trace
 * ID must come from the active span context, or `meta.traceId` will not
 * resolve in Tempo. Random is a placeholder that keeps the envelope shape right.
 */
function newTraceId(): string {
  return randomBytes(16).toString('hex');
}

/** ISO-8601 with milliseconds and Z — `toISOString()` already does exactly this. */
function nowIso(): string {
  return new Date().toISOString();
}

/**
 * Hono middleware stamping every request with a request ID and trace ID.
 *
 * TODO(Phase 1): honour a well-formed inbound X-Request-Id so a caller can
 * correlate across a retry.
 * TODO(Phase 2): extract the W3C `traceparent` header instead of minting one.
 */
export async function requestIdMiddleware(c: Context, next: () => Promise<void>): Promise<void> {
  const requestId = newRequestId();
  c.set('requestId', requestId);
  c.set('traceId', newTraceId());
  c.header('X-Request-Id', requestId);
  await next();
}

export function metaFor(c: Context): Meta {
  return {
    requestId: (c.get('requestId') as string | undefined) ?? newRequestId(),
    timestamp: nowIso(),
    traceId: (c.get('traceId') as string | undefined) ?? newTraceId(),
  };
}

export function success<T>(c: Context, status: number, data: T): Response {
  const body: SuccessEnvelope<T> = { success: true, data, meta: metaFor(c) };
  return c.json(body, status as 200);
}

export function failure(
  c: Context,
  status: number,
  code: string,
  message: string,
  details?: unknown,
): Response {
  const body: ErrorEnvelope = {
    success: false,
    error: details === undefined ? { code, message } : { code, message, details },
    meta: metaFor(c),
  };
  return c.json(body, status as 500);
}

/**
 * The placeholder mounted on every /api/v1 route that is not built yet.
 *
 * It exists so the conformance suite fails loudly and specifically rather than
 * returning a confusing 404.
 *
 * TODO(Phase 1): as each route group is implemented, mount its real router
 * ABOVE the catch-all in src/index.ts. When this stops being reachable, Phase 1
 * is done.
 */
export function notImplemented(c: Context): Response {
  return failure(
    c,
    501,
    'NOT_IMPLEMENTED',
    'Not implemented yet — see docs/learning-roadmap.md Phase 1',
  );
}
