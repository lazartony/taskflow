# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────
FROM golang:1.23-bookworm AS builder

WORKDIR /src

# Dependencies first: this layer only invalidates when go.mod/go.sum change,
# so an edit to main.go does not re-download the module graph.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .

# CGO_ENABLED=0 is what makes the binary static, which is what makes
# distroless/static (rather than /base) a valid runtime.
# -trimpath keeps build paths out of the binary; -s -w drops the symbol table.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/healthcheck ./cmd/healthcheck

# ── Runtime stage ─────────────────────────────────────────────────────────
# No shell, no package manager, no curl. An attacker with RCE gets a process
# and nothing to pivot with (SEC4.8, §8.8 of the resilience spec).
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/server /server
COPY --from=builder /out/healthcheck /healthcheck

# 65532 is the numeric uid of the distroless `nonroot` user. Compose and k8s
# both pin runAsUser: 65532 to match.
USER nonroot:nonroot

EXPOSE 8080

# Distroless has no curl, so the healthcheck is the static binary built above.
# It probes /health/live, never /health/ready — see cmd/healthcheck/main.go.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD ["/healthcheck"]

ENTRYPOINT ["/server"]
