#!/usr/bin/env bash
#
# status.sh — one screen that answers "what is actually running right now?"
#
# Three questions per implementation, because they fail independently and the
# difference tells you where to look:
#
#   container   is the process alive?              → docker ps
#   health      will it serve traffic?             → GET /api/v1/health/ready
#   phase       how much of it is built?           → reports/phase-status.json
#
# A container that is up with a health probe that is down is a broken service.
# A container that is down is a stack you have not started. They need different
# fixes, so they get different columns.
#
# The observability stack is OPTIONAL — `make up` deliberately does not start
# it. Services from that stack which were never created are reported as
# "not started", never as failures; a red row for something you chose not to
# run teaches you to ignore red rows.
#
#   scripts/status.sh
#   scripts/status.sh --watch      # refresh every 5s
#   scripts/status.sh --watch 2
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

WATCH=0
WATCH_SECS=5

usage() {
  cat <<'EOF'
status.sh — health overview of the whole TaskFlow stack

USAGE
  scripts/status.sh [--watch [N]]

OPTIONS
  --watch [N]   redraw every N seconds (default 5); Ctrl-C to stop
  -h, --help

COLUMNS
  container   running / stopped / not started  (docker ps)
  health      ready / live / skeleton / down   (the service's own probes)
  phase       highest phase recorded as passing by scripts/progress.sh

  "skeleton" means the service answers /health/live but GET /api/v1/tasks
  still returns 501 — the Phase 0 catch-all is still mounted.

EXIT STATUS
  0 always. This is a report, not a gate; use check-phase.sh for a verdict.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      WATCH=1; shift
      if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then WATCH_SECS="$1"; shift; fi
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

STATUS_FILE="${REPO_ROOT}/reports/phase-status.json"

# ─────────────────────────────────────────────────────────────────────────────
# Phase column
# ─────────────────────────────────────────────────────────────────────────────
#
# Read once per render rather than once per implementation — the file is the
# merged record of every check-phase.sh run, so five reads would give five
# identical answers at five times the cost.
PHASE_SUMMARY=""

load_phase_summary() {
  PHASE_SUMMARY=""
  [[ -f "${STATUS_FILE}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # "go=0,1,3" per line. phasesPassed is what render_progress.py trusts, so we
  # trust the same field rather than re-deriving a second opinion from the
  # per-phase counts.
  PHASE_SUMMARY="$(jq -r '
    (.summary.phasesPassed // {}) | to_entries[]
    | .key + "=" + ((.value // [])
        | map(sub("^phase"; "") | tonumber) | sort | map(tostring) | join(","))
  ' "${STATUS_FILE}" 2>/dev/null || true)"
}

phase_cell() {
  local impl="$1" line
  if [[ ! -f "${STATUS_FILE}" ]]; then printf 'not measured'; return; fi
  if [[ -z "${PHASE_SUMMARY}" ]]; then printf 'unreadable'; return; fi
  line="$(printf '%s\n' "${PHASE_SUMMARY}" | sed -n "s/^${impl}=//p" | head -1)"
  if [[ -z "${line}" ]]; then printf 'none passing'; return; fi
  # "0,1,2,5" reads better as "0-2, 5" once there are more than a couple.
  local ranges
  ranges="$(printf '%s' "${line}" | awk -F, '
    { start = $1; prev = $1; out = ""
      for (i = 2; i <= NF + 1; i++) {
        cur = (i <= NF) ? $i : -99
        if (cur != prev + 1) {
          seg = (start == prev) ? start : ((prev == start + 1) ? start "," prev : start "-" prev)
          out = (out == "") ? seg : out ", " seg
          start = cur
        }
        prev = cur
      }
      printf "%s", out
    }')"
  if [[ "${ranges}" =~ ^[0-9]+$ ]]; then
    printf 'phase %s' "${ranges}"
  else
    printf 'phases %s' "${ranges}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# One row of the API table
# ─────────────────────────────────────────────────────────────────────────────
container_cell() {
  local name="$1"
  if container_running "${name}"; then
    local h; h="$(container_health "${name}")"
    case "${h}" in
      healthy)   printf 'running|UP' ;;
      starting)  printf 'starting|WARN' ;;
      unhealthy) printf 'unhealthy|FAIL' ;;
      *)         printf 'running|UP' ;;
    esac
  elif container_exists "${name}"; then
    printf 'stopped|DOWN'
  else
    printf 'not started|SKIP'
  fi
}

api_health_cell() {
  local base="$1" live ready
  ready="$(http_status "${base}/api/v1/health/ready" 2)"
  if [[ "${ready}" == "200" ]]; then
    # Ready is not the same as built. A skeleton is perfectly ready to serve
    # 501s, and reporting that as a green "ready" is how you spend an afternoon
    # benchmarking the error path.
    if service_is_501 "${base}"; then printf 'skeleton|WARN'; else printf 'ready|UP'; fi
    return
  fi
  live="$(http_status "${base}/api/v1/health/live" 2)"
  case "${live}" in
    200) printf 'live, not ready|WARN' ;;
    000) printf 'no answer|DOWN' ;;
    *)   printf "live HTTP ${live}|FAIL" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# One row of an infrastructure table
# ─────────────────────────────────────────────────────────────────────────────
service_probe_cell() {
  local key="$1" container="$2" url code

  container_running "${container}" || { printf -- '—|SKIP'; return; }

  case "${key}" in
    postgres)
      if docker exec "${container}" pg_isready -U postgres -d taskflow_dev >/dev/null 2>&1
      then printf 'accepting|UP'; else printf 'not accepting|FAIL'; fi
      return ;;
    valkey)
      if [[ "$(docker exec "${container}" valkey-cli PING 2>/dev/null | tr -d '\r')" == "PONG" ]]
      then printf 'PONG|UP'; else printf 'no PONG|FAIL'; fi
      return ;;
  esac

  url="$(service_probe_url "${key}")"
  [[ -z "${url}" ]] && { printf -- '—|SKIP'; return; }
  code="$(http_status "${url}" 2)"
  case "${code}" in
    200|204) printf 'responding|UP' ;;
    000)     printf 'no answer|FAIL' ;;
    *)       printf "HTTP ${code}|WARN" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Render
# ─────────────────────────────────────────────────────────────────────────────
row() { # label, "text|STATE", "text|STATE", trailing
  local label="$1" a="$2" b="$3" tail="${4:-}"
  printf '  %-12s %s %s %s\n' \
    "${label}" \
    "$(cell "${a%%|*}" 13 "$(state_colour "${a##*|}")")" \
    "$(cell "${b%%|*}" 17 "$(state_colour "${b##*|}")")" \
    "${tail}"
}

render() {
  local docker_ok=1
  have_docker || docker_ok=0

  printf '\n%s  TaskFlow · %s%s\n' "${C_BOLD}" "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${C_RESET}"

  if (( ! docker_ok )); then
    printf '\n'
    fail "the Docker daemon is not reachable — every column below would be a guess"
    printf '      %sStart it (systemctl start docker / open Docker Desktop) and retry.%s\n\n' \
      "${C_DIM}" "${C_RESET}"
    return 0
  fi

  load_phase_summary

  # ── APIs ──
  printf '\n  %sImplementations%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  %s%-12s %-13s %-17s %s%s\n' "${C_DIM}" "service" "container" "health" "progress" "${C_RESET}"
  local impl c base
  # Only the languages this project is using (scripts/use-languages.sh).
  __active=(); while IFS= read -r __l; do [[ -n "$__l" ]] && __active+=("$__l"); done < <(configured_languages)
  for impl in "${__active[@]}"; do
    c="$(impl_container "${impl}")"
    base="$(impl_base_url "${impl}")"
    if container_running "${c}"; then
      row "${impl}" "$(container_cell "${c}")" "$(api_health_cell "${base}")" \
        "$(printf '%s:%s  %s' "port" "$(impl_port "${impl}")" "$(phase_cell "${impl}")")"
    else
      # No HTTP probe when the container is not there: five 2-second timeouts
      # to prove something we already know makes `make status` feel broken.
      row "${impl}" "$(container_cell "${c}")" "—|SKIP" \
        "$(printf '%s:%s  %s' "port" "$(impl_port "${impl}")" "$(phase_cell "${impl}")")"
    fi
  done

  # ── infrastructure ──
  printf '\n  %sInfrastructure%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  %s%-12s %-13s %-17s %s%s\n' "${C_DIM}" "service" "container" "probe" "" "${C_RESET}"
  local svc
  for svc in "${INFRA_SERVICES[@]}"; do
    c="$(service_container "${svc}")"
    row "${svc}" "$(container_cell "${c}")" "$(service_probe_cell "${svc}" "${c}")" "${c}"
  done

  # ── observability ──
  local started=0
  for svc in "${OBS_SERVICES[@]}"; do
    container_exists "$(service_container "${svc}")" && started=1
  done
  printf '\n  %sObservability%s' "${C_BOLD}" "${C_RESET}"
  if (( ! started )); then
    printf ' %s(optional — not started; make up-full)%s\n' "${C_DIM}" "${C_RESET}"
  else
    printf '\n'
  fi
  printf '  %s%-12s %-13s %-17s %s%s\n' "${C_DIM}" "service" "container" "probe" "" "${C_RESET}"
  for svc in "${OBS_SERVICES[@]}"; do
    c="$(service_container "${svc}")"
    row "${svc}" "$(container_cell "${c}")" "$(service_probe_cell "${svc}" "${c}")" "${c}"
  done

  # ── what to do next ──
  local running=0
  __active=(); while IFS= read -r __l; do [[ -n "$__l" ]] && __active+=("$__l"); done < <(configured_languages)
  for impl in "${__active[@]}"; do
    container_running "$(impl_container "${impl}")" && running=$(( running + 1 ))
  done
  printf '\n'
  if (( running == 0 )); then
    warn "no implementation is running"
    printf '      %sStart the stack:  make up      (or scripts/dev-up.sh)%s\n' "${C_DIM}" "${C_RESET}"
  elif ! container_running "${PG_CONTAINER}"; then
    fail "postgres is not running — every implementation will fail readiness"
    printf '      %sTry:  make up%s\n' "${C_DIM}" "${C_RESET}"
  fi
  if [[ ! -f "${STATUS_FILE}" ]]; then
    printf '      %sNo phase results recorded yet — run:  make check PHASE=0%s\n' \
      "${C_DIM}" "${C_RESET}"
  fi

  print_urls auto
}

if (( WATCH )); then
  # Redraw in place. `clear` rather than watch(1) so the colours, the Ctrl-C
  # handling and the "docker is down" path behave the same in both modes.
  trap 'printf "\n"; exit 0' INT
  while true; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    render 2>&1
    printf '  %srefreshing every %ss — Ctrl-C to stop%s\n' "${C_DIM}" "${WATCH_SECS}" "${C_RESET}"
    sleep "${WATCH_SECS}"
  done
fi

render 2>&1
exit 0
