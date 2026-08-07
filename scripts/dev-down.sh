#!/usr/bin/env bash
#
# dev-down.sh — stop the stack.
#
# The counterpart to dev-up.sh. Two things it adds over `docker compose down`:
#
#   it always passes all three compose files, so containers created by
#   `make up-full` are not orphaned when you later run a plain `down` with only
#   the core file — that is how people end up with a Grafana nobody can account
#   for still holding port 3000;
#
#   --volumes tells you exactly what it is about to delete before it does.
#
#   scripts/dev-down.sh
#   scripts/dev-down.sh --volumes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VOLUMES=0
YES=0

usage() {
  cat <<'EOF'
dev-down.sh — stop the TaskFlow stack

USAGE
  scripts/dev-down.sh [--volumes] [--yes]

OPTIONS
  --volumes     also delete the named volumes: the database, the object
                store, the Kafka log, and every Prometheus/Loki/Tempo series.
                Asks first
  --yes         do not ask (for scripts and CI)
  -h, --help

WHAT SURVIVES A PLAIN `dev-down.sh`
  Everything on disk: postgres_data, seaweed_data, redpanda_data and the
  observability volumes. Starting up again gives you the same database.

WHAT --volumes DELETES
  All of it, including every seeded row. Re-seed afterwards:
    scripts/seed.sh --size small --truncate

EXIT STATUS
  0  stopped
  1  docker compose failed
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volumes|-v) VOLUMES=1; shift ;;
    --yes|-y)     YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

require_docker

section "dev-down"

# All three files, always. `docker compose -f docker-compose.yml down` only
# knows about the services in that file; anything started by up-full is left
# running and, worse, is no longer listed by the compose commands you type
# next.
COMPOSE_ARGS=(-f docker-compose.yml -f docker-compose.infra.yml -f docker-compose.observability.yml)

RUNNING="$(compose "${COMPOSE_ARGS[@]}" ps --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
if [[ "${RUNNING}" == "0" ]]; then
  info "nothing is running"
  if (( ! VOLUMES )); then
    exit 0
  fi
  step "continuing anyway — volumes outlive containers"
else
  info "${RUNNING} container(s) to stop"
fi

if (( VOLUMES )); then
  printf '\n' >&2
  warn "--volumes will DELETE all persisted data:"
  local_vols="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep '^taskflow_' || true)"
  if [[ -n "${local_vols}" ]]; then
    while IFS= read -r v; do
      [[ -z "${v}" ]] && continue
      printf '      %s%s%s\n' "${C_YELLOW}" "${v}" "${C_RESET}" >&2
    done <<<"${local_vols}"
  else
    printf '      %s(no taskflow_* volumes exist yet)%s\n' "${C_DIM}" "${C_RESET}" >&2
  fi
  printf '      %severy seeded row, every metric, every trace%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  if (( ! YES )); then
    if [[ -t 0 ]]; then
      read -r -p "      type 'delete' to confirm: " answer
      [[ "${answer}" == "delete" ]] || { info "cancelled — nothing was deleted"; exit 0; }
    else
      fail "--volumes needs a terminal to confirm on, or --yes"
      step "Non-interactive:  scripts/dev-down.sh --volumes --yes"
      exit 2
    fi
  fi
fi

DOWN_ARGS=(down --remove-orphans)
(( VOLUMES )) && DOWN_ARGS+=(-v)

rc=0
compose "${COMPOSE_ARGS[@]}" "${DOWN_ARGS[@]}" || rc=$?

if (( rc != 0 )); then
  fail "docker compose down exited ${rc}"
  step "Something may still be running:  docker ps --filter name=taskflow-"
  exit 1
fi

printf '\n' >&2
if (( VOLUMES )); then
  ok "stopped, and all volumes deleted"
  info "next:  scripts/dev-up.sh && scripts/seed.sh --size small --truncate"
else
  ok "stopped — data volumes kept"
  info "next:  scripts/dev-up.sh          (the database is exactly as you left it)"
  step "To delete the data too:  scripts/dev-down.sh --volumes"
fi
exit 0
