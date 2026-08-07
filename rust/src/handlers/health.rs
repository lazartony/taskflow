//! The three health probes (OBS5).
//!
//! Why three endpoints: a single `/health` that checks the database is the most
//! common self-inflicted outage in production. The database blips, every
//! replica fails its *liveness* probe at once, the orchestrator kills them all,
//! and a recoverable dependency blip becomes a total outage. Liveness answers
//! only "is this process wedged". Readiness answers "should I get traffic now".

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::get;
use axum::{Extension, Router};
use serde_json::json;
use sqlx::PgPool;

use crate::envelope::{failure, success, ReqCtx};

/// OBS5.4 — a probe that hits the database on every call is itself a risk.
const READY_CACHE_TTL: Duration = Duration::from_secs(1);
/// OBS5.4 — hard ceiling on the dependency check.
const READY_TIMEOUT: Duration = Duration::from_secs(2);

/// Shared state for the probes.
#[derive(Clone)]
pub struct HealthState {
    pub pool: PgPool,
    cache: Arc<Mutex<Option<(Instant, bool)>>>,
}

impl HealthState {
    pub fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cache: Arc::new(Mutex::new(None)),
        }
    }

    /// Runs `SELECT 1`, memoising the result for [`READY_CACHE_TTL`].
    ///
    /// The mutex guard is deliberately dropped before the `.await` — holding a
    /// `std::sync::Mutex` across an await point would make this future `!Send`
    /// and can deadlock the runtime.
    async fn check_cached(&self) -> bool {
        {
            let guard = self.cache.lock().expect("health cache mutex poisoned");
            if let Some((checked_at, healthy)) = *guard {
                if checked_at.elapsed() < READY_CACHE_TTL {
                    return healthy;
                }
            }
        }

        let healthy =
            match tokio::time::timeout(READY_TIMEOUT, sqlx::query("SELECT 1").execute(&self.pool))
                .await
            {
                Ok(Ok(_)) => true,
                // Either the query failed or the 2s timeout elapsed. A readiness
                // probe reports "not ready" for both; it never raises a 500 and
                // leaves the orchestrator guessing.
                Ok(Err(_)) | Err(_) => false,
            };

        let mut guard = self.cache.lock().expect("health cache mutex poisoned");
        *guard = Some((Instant::now(), healthy));
        healthy
    }
}

/// Mounts `/live`, `/ready`, `/startup` and the bare alias.
pub fn routes(state: HealthState) -> Router {
    Router::new()
        // OBS5.5 — `/api/v1/health` stays as an alias of `/health/ready`.
        .route("/", get(ready))
        .route("/live", get(live))
        .route("/ready", get(ready))
        .route("/startup", get(startup))
        .with_state(state)
}

/// OBS5.1 — liveness. No dependency checks, ever.
async fn live(Extension(ctx): Extension<ReqCtx>) -> Response {
    success(&ctx, StatusCode::OK, json!({ "status": "alive" }))
}

/// OBS5.2 — readiness.
///
/// TODO(Phase 4): add the Valkey PING here.
/// TODO(Phase 6): add the Kafka broker metadata check here.
async fn ready(State(state): State<HealthState>, Extension(ctx): Extension<ReqCtx>) -> Response {
    if state.check_cached().await {
        success(
            &ctx,
            StatusCode::OK,
            json!({ "status": "ready", "checks": { "database": "up" } }),
        )
    } else {
        // The envelope invariant is absolute: a >=400 status carries
        // success:false and error.code. The detail travels in error.details so
        // an operator still sees which dependency failed.
        failure(
            &ctx,
            StatusCode::SERVICE_UNAVAILABLE,
            "SERVICE_UNAVAILABLE",
            "One or more dependencies are unavailable",
            Some(json!({ "status": "not_ready", "checks": { "database": "down" } })),
        )
    }
}

/// OBS5.3 — startup.
///
/// The pool is created and pinged before the server binds, so reaching this
/// handler at all means startup succeeded.
///
/// TODO(Phase 0/12): also assert the expected schema_migrations version, so a
/// replica pointed at an un-migrated database never reports started.
async fn startup(Extension(ctx): Extension<ReqCtx>) -> Response {
    success(&ctx, StatusCode::OK, json!({ "status": "started" }))
}
