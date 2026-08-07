//! The HTTP response envelope and the request-scoped identifiers every
//! TaskFlow response carries.
//!
//! The shape here is normative — the language-neutral conformance suite asserts
//! it across all five implementations. Do not change a field name without
//! changing the other four services too.

use axum::extract::Request;
use axum::http::{HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::Json;
use rand::Rng;
use serde::Serialize;
use serde_json::Value;

const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const HEX: &[u8] = b"0123456789abcdef";

/// Present on every response, success or error.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Meta {
    /// Human-quotable support identifier, `^req_[a-zA-Z0-9]+$`.
    pub request_id: String,
    /// ISO-8601 with milliseconds and a literal Z suffix.
    pub timestamp: String,
    /// 32 lowercase hex — the key into Tempo (OBS4.7).
    pub trace_id: String,
}

#[derive(Debug, Serialize)]
pub struct SuccessEnvelope {
    pub success: bool,
    pub data: Value,
    pub meta: Meta,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub success: bool,
    pub error: ErrorBody,
    pub meta: Meta,
}

/// Request-scoped identifiers, inserted into the request extensions by
/// [`request_context`] and pulled out by handlers via `Extension<ReqCtx>`.
#[derive(Debug, Clone)]
pub struct ReqCtx {
    pub request_id: String,
    pub trace_id: String,
}

impl ReqCtx {
    pub fn new() -> Self {
        Self {
            request_id: new_request_id(),
            trace_id: new_trace_id(),
        }
    }

    pub fn meta(&self) -> Meta {
        Meta {
            request_id: self.request_id.clone(),
            timestamp: now_iso(),
            trace_id: self.trace_id.clone(),
        }
    }
}

impl Default for ReqCtx {
    fn default() -> Self {
        Self::new()
    }
}

/// `req_` followed by 12 alphanumeric characters.
pub fn new_request_id() -> String {
    let mut rng = rand::thread_rng();
    let mut s = String::with_capacity(16);
    s.push_str("req_");
    for _ in 0..12 {
        s.push(ALPHABET[rng.gen_range(0..ALPHABET.len())] as char);
    }
    s
}

/// 32 lowercase hex characters.
///
/// TODO(Phase 2): delete this. Once the OpenTelemetry SDK is wired up the trace
/// ID must come from the active span context, or `meta.traceId` will not
/// resolve in Tempo. Random is a placeholder that keeps the envelope correct.
fn new_trace_id() -> String {
    let mut rng = rand::thread_rng();
    let mut s = String::with_capacity(32);
    for _ in 0..32 {
        s.push(HEX[rng.gen_range(0..16)] as char);
    }
    s
}

/// ISO-8601 with milliseconds and a literal Z suffix.
fn now_iso() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

/// Middleware stamping every request with a request ID and trace ID.
///
/// TODO(Phase 1): honour a well-formed inbound `X-Request-Id` so a caller can
/// correlate across a retry.
/// TODO(Phase 2): extract the W3C `traceparent` header instead of minting one.
pub async fn request_context(mut req: Request, next: Next) -> Response {
    let ctx = ReqCtx::new();
    let request_id = ctx.request_id.clone();
    req.extensions_mut().insert(ctx);

    let mut res = next.run(req).await;
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        res.headers_mut().insert("x-request-id", value);
    }
    res
}

/// Renders the `{success: true, data, meta}` envelope.
pub fn success(ctx: &ReqCtx, status: StatusCode, data: Value) -> Response {
    (
        status,
        Json(SuccessEnvelope {
            success: true,
            data,
            meta: ctx.meta(),
        }),
    )
        .into_response()
}

/// Renders the `{success: false, error, meta}` envelope.
pub fn failure(
    ctx: &ReqCtx,
    status: StatusCode,
    code: &str,
    message: &str,
    details: Option<Value>,
) -> Response {
    (
        status,
        Json(ErrorEnvelope {
            success: false,
            error: ErrorBody {
                code: code.to_string(),
                message: message.to_string(),
                details,
            },
            meta: ctx.meta(),
        }),
    )
        .into_response()
}

/// The fallback for every `/api/v1` route that is not built yet.
///
/// It exists so the conformance suite fails loudly and specifically rather than
/// returning a confusing 404.
///
/// TODO(Phase 1): as each router is implemented, nest it ABOVE this fallback in
/// `main.rs`. When this stops being reachable, Phase 1 is done.
pub async fn not_implemented(ctx: Option<axum::Extension<ReqCtx>>) -> Response {
    let ctx = ctx.map(|e| e.0).unwrap_or_default();
    failure(
        &ctx,
        StatusCode::NOT_IMPLEMENTED,
        "NOT_IMPLEMENTED",
        "Not implemented yet — see docs/learning-roadmap.md Phase 1",
        None,
    )
}
