# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────
#
# Pinned to the MSRV declared in Cargo.toml. Edition 2021 uses resolver v2,
# which is NOT MSRV-aware: `cargo update` can pull in a transitive dependency
# that requires a newer rustc than this tag, and the failure shows up here
# rather than at `cargo check` on a dev machine with a current toolchain. If
# that happens, either bump this tag or pin the offending crate back.
FROM rust:1.97-bookworm AS builder

WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY src ./src

# The cache mounts make an incremental rebuild fast, but anything written to a
# cache mount is gone once the RUN ends — so the binaries are copied out to
# /out inside the same layer.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked --bins && \
    mkdir -p /out && \
    cp target/release/taskflow /out/server && \
    cp target/release/healthcheck /out/healthcheck

# ── Runtime stage ─────────────────────────────────────────────────────────
# cc-debian12 rather than static-debian12: this binary links glibc dynamically.
# Still no shell, no package manager, no curl — an attacker with RCE gets a
# process and nothing to pivot with (SEC4.8, §8.8 of the resilience spec).
FROM gcr.io/distroless/cc-debian12:nonroot

COPY --from=builder /out/server /server
COPY --from=builder /out/healthcheck /healthcheck

# 65532 is the numeric uid of the distroless `nonroot` user. Compose and k8s
# both pin runAsUser: 65532 to match.
USER nonroot:nonroot

EXPOSE 8080

# Distroless has no curl, so the healthcheck is the std-only binary built above.
# It probes /health/live, never /health/ready — see src/bin/healthcheck.rs.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD ["/healthcheck"]

ENTRYPOINT ["/server"]
