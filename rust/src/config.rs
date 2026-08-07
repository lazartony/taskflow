//! Runtime configuration, read from the environment.
//!
//! Every key here appears in the repository-root `.env.example`. Only the
//! subset the skeleton actually uses is parsed; the rest arrive in later phases.

use std::env;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    pub env: String,
    pub service_name: String,
    pub service_version: String,
    pub log_level: String,
    pub database_url: String,
    pub database_pool_size: u32,
    pub database_min_idle: u32,
    pub database_acquire_timeout: Duration,
    pub shutdown_prestop_delay: Duration,
    // TODO(Phase 1): jwt_secret, jwt_issuer, jwt_audience, jwt_access_expiry,
    //   jwt_refresh_expiry, bcrypt_cost, cors_origins, max_body_bytes.
    // TODO(Phase 4): valkey_url, cache_enabled, rate_limit_* keys.
    // TODO(Phase 6): kafka_brokers, outbox_* keys.
    // TODO(Phase 10): s3_endpoint, s3_bucket, s3_access_key, s3_secret_key.
}

impl Config {
    /// Reads the environment and fails fast on anything missing or malformed.
    ///
    /// Failing at startup beats failing on the first request that needs the value.
    pub fn from_env() -> Result<Self, String> {
        let database_url = env::var("DATABASE_URL").unwrap_or_default();
        if database_url.is_empty() {
            return Err("DATABASE_URL is required".to_string());
        }

        Ok(Self {
            port: parse_num("PORT", 8080)?,
            env: string_or("ENV", "development"),
            service_name: string_or("OTEL_SERVICE_NAME", "taskflow-rust"),
            service_version: string_or("OTEL_SERVICE_VERSION", "1.0.0"),
            log_level: string_or("LOG_LEVEL", "info"),
            database_url,
            database_pool_size: parse_num("DATABASE_POOL_SIZE", 10)?,
            database_min_idle: parse_num("DATABASE_MIN_IDLE", 2)?,
            database_acquire_timeout: Duration::from_millis(parse_num(
                "DATABASE_ACQUIRE_TIMEOUT_MS",
                2000,
            )?),
            shutdown_prestop_delay: parse_duration("SHUTDOWN_PRESTOP_DELAY", 5),
        })
    }
}

fn string_or(key: &str, fallback: &str) -> String {
    match env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => fallback.to_string(),
    }
}

fn parse_num<T: std::str::FromStr>(key: &str, fallback: T) -> Result<T, String> {
    match env::var(key) {
        Ok(v) if !v.is_empty() => v
            .parse::<T>()
            .map_err(|_| format!("{key} must be a number, got {v:?}")),
        _ => Ok(fallback),
    }
}

/// Parses a Go-style duration ("30s", "5m", "1500ms") into a `Duration`.
///
/// `.env.example` uses that format for the shutdown keys, so all five services
/// have to understand it. An unparseable value falls back rather than failing
/// startup — these are tuning knobs, not correctness-critical.
fn parse_duration(key: &str, fallback_secs: u64) -> Duration {
    let raw = match env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => return Duration::from_secs(fallback_secs),
    };
    let raw = raw.trim();

    let (digits, multiplier_ms) = if let Some(d) = raw.strip_suffix("ms") {
        (d, 1_u64)
    } else if let Some(d) = raw.strip_suffix('s') {
        (d, 1_000)
    } else if let Some(d) = raw.strip_suffix('m') {
        (d, 60_000)
    } else if let Some(d) = raw.strip_suffix('h') {
        (d, 3_600_000)
    } else {
        return Duration::from_secs(fallback_secs);
    };

    match digits.parse::<u64>() {
        Ok(n) => Duration::from_millis(n * multiplier_ms),
        Err(_) => Duration::from_secs(fallback_secs),
    }
}
