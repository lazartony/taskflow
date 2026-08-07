# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────
#
# The interpreter version here is NOT arbitrary. The runtime stage is
# gcr.io/distroless/python3-debian13, which ships CPython 3.13, and asyncpg is
# a C extension: its wheel is built against a specific Python ABI. Build the
# venv on 3.12 and copy it into a 3.13 runtime and the import fails at startup
# with a missing .so. Builder and runtime must match exactly.
#
# The -slim-trixie tag is deliberate too: trixie is Debian 13, so the builder's
# glibc matches the distroless/*-debian13 runtime's.
#
# If you move to a newer distroless base, bump BOTH this tag and the
# site-packages path in PYTHONPATH below.
FROM python:3.13-slim-trixie AS builder

WORKDIR /build

# Build toolchain for any dependency without a manylinux wheel. It stays in the
# builder; the runtime image never sees a compiler.
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    rm -rf /var/lib/apt/lists/*

# Distroless has no pip, so dependencies are vendored into a venv here and the
# whole venv is copied into the runtime image.
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

COPY pyproject.toml README.md ./
COPY app ./app

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir .

# Build the /healthcheck shim: same source as scripts/healthcheck.py, plus a
# shebang pointing at the runtime image's interpreter, so compose's shared
# `test: ["CMD", "/healthcheck"]` anchor works here the way it does for Go, Rust
# and TypeScript. Without it this service is permanently unhealthy — the anchor
# overrides the HEALTHCHECK below, and there is no /healthcheck to run.
COPY scripts ./scripts
RUN printf '#!/usr/bin/python3\n' > /healthcheck && \
    cat scripts/healthcheck.py >> /healthcheck && \
    chmod 0755 /healthcheck

# ── Runtime stage ─────────────────────────────────────────────────────────
# No shell, no package manager, no curl, no pip. An attacker with RCE gets a
# process and nothing to pivot with (SEC4.8, §8.8 of the resilience spec).
FROM gcr.io/distroless/python3-debian13:nonroot

WORKDIR /app

# The venv's bin/ scripts are useless here (no shell, and their shebangs point
# at /venv/bin/python which does not exist in this image). Only site-packages
# matters, reached via PYTHONPATH.
COPY --from=builder /venv/lib/python3.13/site-packages /venv/lib/python3.13/site-packages
COPY app ./app
COPY scripts ./scripts
COPY --from=builder /healthcheck /healthcheck

ENV PYTHONPATH=/venv/lib/python3.13/site-packages:/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# 65532 is the numeric uid of the distroless `nonroot` user. Compose and k8s
# both pin runAsUser: 65532 to match.
USER nonroot:nonroot

EXPOSE 8080

# The base image's ENTRYPOINT is already `python3`, so CMD is the script path.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD ["/usr/bin/python3", "/app/scripts/healthcheck.py"]

CMD ["-m", "app.main"]
