//! Container HEALTHCHECK for the distroless image.
//!
//! Distroless has no shell, no curl and no wget, so the healthcheck has to be a
//! binary. This one is std-only — no HTTP client crate — because a readiness
//! probe should not drag `reqwest` and its TLS stack into the build.
//!
//! It deliberately probes LIVE, not READY. Docker restarts an unhealthy
//! container; restarting because the database blipped is exactly the outage the
//! three-endpoint split exists to prevent (OBS5.1).

use std::env;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::ExitCode;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(2);

fn main() -> ExitCode {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());

    match probe(&port) {
        Ok(true) => ExitCode::SUCCESS,
        _ => ExitCode::FAILURE,
    }
}

fn probe(port: &str) -> std::io::Result<bool> {
    let mut stream = TcpStream::connect(format!("127.0.0.1:{port}"))?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;

    // A hand-written request is entirely reasonable for one fixed endpoint.
    // Connection: close means the server hangs up and the read below terminates.
    let request = format!(
        "GET /api/v1/health/live HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes())?;
    stream.flush()?;

    // The status line is all that matters, so cap the read rather than
    // buffering an arbitrarily large body.
    let mut buf = [0_u8; 128];
    let n = stream.read(&mut buf)?;
    let head = String::from_utf8_lossy(&buf[..n]);

    Ok(head.starts_with("HTTP/1.1 200") || head.starts_with("HTTP/1.0 200"))
}
