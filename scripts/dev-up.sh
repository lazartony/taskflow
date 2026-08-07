#!/usr/bin/env bash
#
# dev-up.sh — start the stack, with a better first five minutes than raw
# `docker compose up`.
#
# Three things it does that compose does not:
#
#   .env       creates one if it is missing, with a random JWT_SECRET, instead
#              of starting every service with "variable is not set" warnings
#              and a default secret.
#
#   ports      checks them BEFORE starting anything and names the process
#              holding the conflicting one. Compose's own message is
#              "Bind for 0.0.0.0:5432 failed: port is already allocated",
#              which names the container it could not create and says nothing
#              about the Postgres you installed with brew two years ago.
#
#   the end    prints the URLs and the health of what it just started, so
#              "is it up?" does not need a second command.
#
#   scripts/dev-up.sh
#   scripts/dev-up.sh --full          # + the observability stack
#   scripts/dev-up.sh --impl go       # Postgres, Valkey, S3 and one API
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FULL=0
ONE_IMPL=""
BUILD=1
WAIT_TIMEOUT=300
DO_WAIT=1

usage() {
  cat <<'EOF'
dev-up.sh — start the TaskFlow stack

USAGE
  scripts/dev-up.sh [options]

OPTIONS
  --full             also start the observability stack (Grafana, Prometheus,
                     Loki, Tempo, Pyroscope, the collector) — about +1 GB RAM
  --impl <lang>      start Postgres, Valkey, SeaweedFS and ONE implementation
  --no-build         do not rebuild images (much faster if nothing changed)
  --no-wait          return as soon as the containers are created, without
                     waiting for them to become healthy
  --wait-timeout N   seconds to wait for health (default 300). The first build
                     of the Rust and .NET images can take a while
  -h, --help

EXIT STATUS
  0  everything requested is up
  1  a port conflict, a build failure, or a service that never became healthy
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)         FULL=1; shift ;;
    --impl)         ONE_IMPL="${2:?--impl needs a value}"; shift 2 ;;
    --no-build)     BUILD=0; shift ;;
    --no-wait)      DO_WAIT=0; shift ;;
    --wait-timeout) WAIT_TIMEOUT="${2:?--wait-timeout needs seconds}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

if [[ -n "${ONE_IMPL}" ]]; then
  is_impl "${ONE_IMPL}" || { fail "unknown implementation '${ONE_IMPL}' (expected: ${IMPLS_ALL[*]})"; exit 2; }
  (( FULL )) && { fail "--impl and --full together do not make sense"; exit 2; }
fi
[[ "${WAIT_TIMEOUT}" =~ ^[0-9]+$ && "${WAIT_TIMEOUT}" -gt 0 ]] || { fail "--wait-timeout must be a positive integer"; exit 2; }

require_docker

section "dev-up"

# ─────────────────────────────────────────────────────────────────────────────
# 1. .env
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  step ".env present"
  secret="$(env_file_value JWT_SECRET || true)"
  if [[ -z "${secret}" ]]; then
    warn ".env has no JWT_SECRET — the compose default will be used"
    step "That default is in a file in the repository. Fine for local work,"
    step "never anywhere else. Add one:  echo \"JWT_SECRET=\$(openssl rand -hex 32)\" >> .env"
  elif (( ${#secret} < 32 )); then
    warn "JWT_SECRET is only ${#secret} characters"
    step "HS256 keys shorter than the 256-bit digest weaken the signature."
  fi
else
  info "no .env — creating one"
  ensure_env_file
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. ports
# ─────────────────────────────────────────────────────────────────────────────
wanted_ports() {
  if [[ -n "${ONE_IMPL}" ]]; then
    printf '5432 postgres\n6379 valkey\n8333 seaweedfs-s3\n9333 seaweedfs-master\n'
    printf '%s %s-api\n' "$(impl_port "${ONE_IMPL}")" "${ONE_IMPL}"
    return
  fi
  core_ports
  infra_ports
  (( FULL )) && obs_ports
  return 0
}

CONFLICTS=()
ALREADY=()
while read -r port svc; do
  [[ -z "${port}" ]] && continue
  listener="$(port_listener "${port}" 2>/dev/null || true)"
  [[ -z "${listener}" ]] && continue
  owner="$(port_container "${port}" 2>/dev/null || true)"
  if [[ "${owner}" == taskflow-* ]]; then
    # Ours. Compose will reuse or recreate it; not a conflict.
    ALREADY+=("${port} ${svc} (${owner})")
  elif [[ -n "${owner}" ]]; then
    CONFLICTS+=("${port}|${svc}|docker container '${owner}'")
  else
    CONFLICTS+=("${port}|${svc}|${listener}")
  fi
done < <(wanted_ports)

if (( ${#ALREADY[@]} )); then
  step "${#ALREADY[@]} port(s) already served by TaskFlow containers — they will be reused"
fi

if (( ${#CONFLICTS[@]} )); then
  printf '\n' >&2
  fail "${#CONFLICTS[@]} port conflict(s) — nothing was started"
  printf '\n  %s%-8s %-24s %s%s\n' "${C_DIM}" "port" "wanted by" "currently held by" "${C_RESET}" >&2
  for c in "${CONFLICTS[@]}"; do
    IFS='|' read -r p s h <<<"${c}"
    printf '  %-8s %-24s %s%s%s\n' "${p}" "${s}" "${C_YELLOW}" "${h}" "${C_RESET}" >&2
  done
  printf '\n  %sOptions:%s\n' "${C_BOLD}" "${C_RESET}" >&2
  printf '    stop the other process, or\n' >&2
  printf '    stop a previous TaskFlow stack:   scripts/dev-down.sh\n' >&2
  printf '    change the host-side port in docker-compose.yml (the "8001:8080"\n' >&2
  printf '    form — only the left half is yours to change)\n\n' >&2
  exit 1
fi
step "all required ports are free"

# ─────────────────────────────────────────────────────────────────────────────
# 3. up
# ─────────────────────────────────────────────────────────────────────────────
COMPOSE_ARGS=(-f docker-compose.yml -f docker-compose.infra.yml)
(( FULL )) && COMPOSE_ARGS+=(-f docker-compose.observability.yml)

UP_ARGS=(up -d)
(( BUILD )) && UP_ARGS+=(--build)

SERVICES=()
if [[ -n "${ONE_IMPL}" ]]; then
  SERVICES=(postgres valkey seaweedfs "$(impl_service "${ONE_IMPL}")")
fi

# The one-shot jobs run once and exit. `up --wait` counts an exited container as
# a failure — even exit 0 — so waiting on the whole set reports a healthy stack
# as broken. They are started in the first pass and left out of the second.
# See the same note in the Makefile.
ONESHOT=(migrate valkey-init valkey-streams-init seaweedfs-init redpanda-init)

wait_targets() { # → the services that are supposed to stay running
  local svc keep
  # config --services honours COMPOSE_PROFILES, so a one-language project does
  # not sit waiting for four APIs that were never started.
  while IFS= read -r svc; do
    [[ -z "${svc}" ]] && continue
    keep=1
    for one in "${ONESHOT[@]}"; do [[ "${svc}" == "${one}" ]] && keep=0 && break; done
    (( keep )) && printf '%s\n' "${svc}"
  done < <(compose "${COMPOSE_ARGS[@]}" config --services 2>/dev/null)
}

printf '\n' >&2
if [[ -n "${ONE_IMPL}" ]]; then
  info "starting postgres, valkey, seaweedfs and ${ONE_IMPL}-api"
elif (( FULL )); then
  info "starting the core stack, infrastructure and observability"
else
  info "starting the core stack and infrastructure"
fi
(( BUILD )) && step "images will be rebuilt where the context changed (--no-build to skip)"
(( DO_WAIT )) && step "waiting up to ${WAIT_TIMEOUT}s for health checks"

# Compose's own progress output goes straight through — it is the best
# available answer to "what is it doing right now" during a long first build.
rc=0
compose "${COMPOSE_ARGS[@]}" "${UP_ARGS[@]}" "${SERVICES[@]}" || rc=$?

if (( rc == 0 && DO_WAIT )); then
  WAIT_SET=()
  if (( ${#SERVICES[@]} )); then
    WAIT_SET=("${SERVICES[@]}")          # --one already names only long-running services
  else
    while IFS= read -r svc; do WAIT_SET+=("${svc}"); done < <(wait_targets)
  fi
  if (( ${#WAIT_SET[@]} )); then
    compose "${COMPOSE_ARGS[@]}" up -d --no-recreate \
      --wait --wait-timeout "${WAIT_TIMEOUT}" "${WAIT_SET[@]}" || rc=$?
  fi
fi

if (( rc != 0 )); then
  printf '\n' >&2
  fail "docker compose exited ${rc}"
  printf '\n  %sMost likely causes, in order:%s\n' "${C_BOLD}" "${C_RESET}" >&2
  printf '    a build failed          — the error is above, in the build output\n' >&2
  printf '    a service never became healthy:\n' >&2
  printf '      docker compose ps                        which one\n' >&2
  printf '      docker compose logs --tail=80 <service>  why\n' >&2
  printf '    the first Rust or .NET build exceeded %ss — retry with\n' "${WAIT_TIMEOUT}" >&2
  printf '      scripts/dev-up.sh --wait-timeout 900\n\n' >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. what you got
# ─────────────────────────────────────────────────────────────────────────────
printf '\n' >&2
ok "stack is up"

if [[ -x "${SCRIPT_DIR}/status.sh" ]]; then
  "${SCRIPT_DIR}/status.sh" || true
else
  print_urls "$( (( FULL )) && echo yes || echo auto )"
fi

# One nudge, chosen by what is actually missing, rather than a wall of advice.
if [[ ! -f "${REPO_ROOT}/benchmarks/seed-manifest.json" ]]; then
  info "next:  scripts/seed.sh --size small --truncate    (deterministic fixtures)"
elif [[ ! -f "${REPO_ROOT}/reports/phase-status.json" ]]; then
  info "next:  make check PHASE=0                         (does the skeleton stand up?)"
else
  info "next:  make progress                              (where you left off)"
fi
exit 0
