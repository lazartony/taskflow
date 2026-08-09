# syntax=docker/dockerfile:1

# ── Build stage ───────────────────────────────────────────────────────────
FROM node:26-bookworm-slim AS builder

WORKDIR /app

# Dependencies first: this layer only invalidates when the lockfile changes.
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
COPY scripts ./scripts

# tsx is a dev-time convenience. The image runs plain compiled JS so the
# runtime needs no transpiler and no dev dependencies.
RUN npm run build

# Build the /healthcheck shim: same source as scripts/healthcheck.cjs, plus a
# shebang, so compose's `test: ["CMD", "/healthcheck"]` anchor works here too.
# A file with no extension is parsed as CommonJS, which is why that file is .cjs.
RUN printf '#!/nodejs/bin/node\n' > /healthcheck && \
    cat scripts/healthcheck.cjs >> /healthcheck && \
    chmod 0755 /healthcheck

# Drop dev dependencies (typescript, tsx, @types/*) from node_modules.
RUN npm ci --omit=dev

# ── Runtime stage ─────────────────────────────────────────────────────────
# No shell, no package manager, no curl. An attacker with RCE gets a process
# and nothing to pivot with (SEC4.8, §8.8 of the resilience spec).
FROM gcr.io/distroless/nodejs24-debian12:nonroot

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /healthcheck /healthcheck

# 65532 is the numeric uid of the distroless `nonroot` user. Compose and k8s
# both pin runAsUser: 65532 to match.
USER nonroot:nonroot

EXPOSE 8080

# The base image's ENTRYPOINT is already `node`, so CMD is just the script path.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
    CMD ["/nodejs/bin/node", "/app/scripts/healthcheck.cjs"]

CMD ["dist/index.js"]
