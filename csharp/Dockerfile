# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS builder

WORKDIR /src

# Project files first: this layer only invalidates when a PackageReference
# changes, so an edit to Program.cs does not re-restore NuGet.
COPY TaskFlow.sln ./
COPY TaskFlow.Api/TaskFlow.Api.csproj TaskFlow.Api/
RUN dotnet restore TaskFlow.Api/TaskFlow.Api.csproj

COPY . .
RUN dotnet publish TaskFlow.Api/TaskFlow.Api.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

# ── Runtime stage ─────────────────────────────────────────────────────────
# Chiselled: no shell, no package manager, no curl, and non-root by default.
# An attacker with RCE gets a process and nothing to pivot with (SEC4.8).
# "-extra" over plain chiselled because it carries ICU and the globalization
# data that Npgsql and DateTime formatting expect.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra

WORKDIR /app
COPY --from=builder /app/publish .

# APP_UID is defined by the base image (uid 1654, user "app"). Using the
# variable rather than a hard-coded number keeps this correct if Microsoft
# changes it.
USER $APP_UID

EXPOSE 8080

# No curl in a chiselled image, so the check re-invokes this same executable
# with --healthcheck; see HealthCheckCommand in Program.cs. It probes
# /health/live, never /health/ready.
#
# Note: docker-compose.yml's shared x-healthcheck anchor is `["CMD", "/healthcheck"]`,
# which suits the Go and Rust images. This service needs the anchor overridden
# with the command below — see README.md.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD ["/app/TaskFlow.Api", "--healthcheck"]

ENTRYPOINT ["/app/TaskFlow.Api"]
