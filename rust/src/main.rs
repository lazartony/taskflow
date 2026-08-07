//! TaskFlow Rust API.
//!
//! This is a SKELETON. It starts, connects to Postgres, serves the three health
//! probes for real, and answers 501 NOT_IMPLEMENTED for every other `/api/v1`
//! route. Everything else is a TODO pointing at the roadmap phase that builds it.

use std::net::{Ipv4Addr, SocketAddr};
use std::process::ExitCode;
use std::sync::OnceLock;
use std::time::Duration;

/// Service resource attributes, set once by [`init_logging`].
static SERVICE: OnceLock<(String, String)> = OnceLock::new();

fn service_attrs() -> (&'static str, &'static str) {
    SERVICE
        .get()
        .map(|(name, version)| (name.as_str(), version.as_str()))
        .unwrap_or(("taskflow-rust", "1.0.0"))
}

/// Emits an info line carrying the service resource attributes.
///
/// `tracing-subscriber`'s JSON formatter has no notion of constant per-event
/// fields, so they are threaded through here rather than repeated at every
/// call site.
///
/// TODO(Phase 2): delete this. The OTel layer attaches the resource once and
/// every event inherits it, along with trace_id and span_id.
macro_rules! log_info {
    ($($arg:tt)*) => {{
        let (svc_name, svc_version) = $crate::service_attrs();
        tracing::info!(service.name = svc_name, service.version = svc_version, $($arg)*);
    }};
}

mod config;
mod envelope;
mod handlers;

use axum::Router;
use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::envelope::{not_implemented, request_context};
use crate::handlers::health::{self, HealthState};

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            // Logging may not be initialised yet, so this goes to stderr raw.
            eprintln!(r#"{{"level":"error","message":"fatal","error":"{err}"}}"#);
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cfg = Config::from_env()?;
    init_logging(&cfg);

    // ── Database pool ────────────────────────────────────────────────────
    let pool = PgPoolOptions::new()
        .max_connections(cfg.database_pool_size)
        .min_connections(cfg.database_min_idle)
        .acquire_timeout(cfg.database_acquire_timeout)
        // TODO(Phase 3): max_lifetime and idle_timeout from DATABASE_MAX_LIFETIME,
        //   plus a statement_timeout via after_connect.
        .connect(&cfg.database_url)
        .await?;

    // Fail fast: a service that cannot reach its database should not start.
    sqlx::query("SELECT 1").execute(&pool).await?;
    log_info!(max_conns = cfg.database_pool_size, "database pool ready");

    // ── Router ───────────────────────────────────────────────────────────
    let api = Router::new()
        .nest("/health", health::routes(HealthState::new(pool.clone())))
        // TODO(Phase 1):  .nest("/auth", handlers::auth::routes(state.clone()))
        // TODO(Phase 1):  .nest("/tasks", handlers::tasks::routes(state.clone()))
        // TODO(Phase 10): .nest("/attachments", handlers::attachments::routes(state))
        //
        // Everything else is deliberately 501. Nest real routers ABOVE this
        // fallback; when it stops being reachable, Phase 1 is done.
        .fallback(not_implemented);

    let app = Router::new()
        .nest("/api/v1", api)
        .layer(axum::middleware::from_fn(request_context));

    // TODO(Phase 1): tower-http layers for CORS, security headers, body limit.
    // TODO(Phase 2): tracing-opentelemetry layer for SERVER spans.
    // TODO(Phase 4): valkey-backed rate limiting.
    // TODO(Phase 5): tower::limit::ConcurrencyLimitLayer for load shedding.

    // ── Serve ────────────────────────────────────────────────────────────
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, cfg.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    log_info!(addr = %addr, env = %cfg.env, "http server listening");

    let prestop = cfg.shutdown_prestop_delay;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal(prestop))
        .await?;

    // axum::serve returns once every in-flight request has finished, so the
    // pool can be closed safely here.
    //
    // TODO(Phase 6): drain the outbox relay and Kafka consumer here, before the
    // pool closes — they hold connections too.
    pool.close().await;
    log_info!("shutdown complete");
    Ok(())
}

/// Resolves on SIGTERM or Ctrl-C, then waits out the pre-stop delay.
///
/// The delay exists so the load balancer notices we are going away before we
/// stop accepting. Without it, in-flight routing sends requests to a socket
/// that is already closed.
///
/// TODO(if you deploy this): flip readiness to "not ready" here as well, so an
/// orchestrator pulls this instance out of rotation during the delay. Kubernetes
/// itself is off the roadmap on purpose — see "Cut: Kubernetes deployment" in
/// docs/learning-roadmap.md.
async fn shutdown_signal(prestop_delay: Duration) {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl-C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => log_info!(signal = "SIGINT", "shutdown signal received"),
        _ = terminate => log_info!(signal = "SIGTERM", "shutdown signal received"),
    }

    tokio::time::sleep(prestop_delay).await;
}

/// Structured JSON logs to stdout.
///
/// TODO(Phase 2): replace with a `tracing-opentelemetry` layer that emits the
/// full canonical log line from §4.1 — nested `service.name`/`service.version`
/// objects plus `trace_id`, `span_id` and `trace_flags` from the active span.
/// Until then the service attributes are flat dotted keys, which Loki and the
/// OTel collector both understand.
fn init_logging(cfg: &Config) {
    let _ = SERVICE.set((cfg.service_name.clone(), cfg.service_version.clone()));

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(format!("{},sqlx=warn", cfg.log_level)));

    tracing_subscriber::fmt()
        .json()
        .flatten_event(true)
        .with_current_span(false)
        .with_span_list(false)
        .with_env_filter(filter)
        .with_writer(std::io::stdout)
        .init();

    log_info!(env = %cfg.env, "logging initialised");
}
