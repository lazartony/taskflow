#!/usr/bin/env bash
#
# chaos.sh — break one thing on purpose and check the service behaves as the
# resilience specification says it will.
#
# The experiments are numbered exactly as in
# docs/resilience-and-security-specification.md §12. Each one:
#
#   1. starts light background load (open-loop k6, so a degrading service does
#      not quietly reduce the offered rate and hide the degradation)
#   2. applies the fault
#   3. observes for a fixed window with an INDEPENDENT probe loop — the probes,
#      not k6's summary, are what the assertions read, because k6 aggregates
#      and the interesting behaviour is per-request
#   4. restores, always, even on Ctrl-C
#   5. asserts the expected behaviour and prints PASS or FAIL with what was
#      actually observed
#
# EXPERIMENT 3 IS THE ONE THAT MATTERS
#   Database down: readiness must fail and liveness must PASS. If liveness
#   fails when the database is down, Kubernetes restarts every replica — all
#   of them healthy, all of them killed — during a database blip that would
#   otherwise have recovered on its own. A thirty-second failover becomes a
#   full outage plus a thundering herd of cold starts against a database that
#   is only just back. Its output below is deliberately the loudest.
#
#   scripts/chaos.sh 3
#   scripts/chaos.sh 1 --impl rust --observe 45
#   scripts/chaos.sh --list
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:latest}"
IMPL="go"
OBSERVE=30
LOAD_RATE=30
PROBE_INTERVAL="0.5"
NO_LOAD=0
EXPERIMENT=""

usage() {
  cat <<'EOF'
chaos.sh — run one chaos experiment from the resilience spec §12

USAGE
  scripts/chaos.sh <N> [options]
  scripts/chaos.sh --list

  <N>  1..12

OPTIONS
  --impl <lang>   which implementation to observe (default go)
  --observe N     seconds to hold the fault (default 30)
  --rate N        background arrival rate in rps (default 30)
  --no-load       do not start k6; probe only. Faster, and enough for
                  experiments 3 and 6
  --list          print the experiment table and exit
  -h, --help

SAFETY
  Every experiment restores what it broke on exit, including on Ctrl-C.
  Nothing here is safe to run against anything you care about: it stops
  containers and adds packet delay to interfaces.

EXIT STATUS
  0  every assertion held
  1  at least one did not
  2  bad arguments
EOF
}

list_experiments() {
  cat <<'EOF'

  Chaos experiments — docs/resilience-and-security-specification.md §12

   #  experiment                     expected
   1  Cache down                     200s continue; latency up; breaker opens; zero 5xx
   2  Cache slow (500ms)             200ms command timeout trips; falls through to DB
   3  DB down                        503 + Retry-After; readiness FAILS; liveness PASSES
   4  DB slow (2s)                   pool saturates; pending-requests rises before latency
   5  Broker down                    writes succeed; outbox backlog climbs; drains on restart
   6  Collector down                 no user-visible impact at all
   7  Storage down                   attachments 503; tasks unaffected
   8  SIGTERM a replica mid-request  zero dropped requests; WebSockets close 1001
   9  Traffic 10x                    load shedding engages; p99 for served requests bounded
  10  Poison message                 DLQ receives it; the partition keeps moving
  11  Clock skew (5 min)             JWT skew tolerance holds
  12  Connection exhaustion (500)    idle timeout reclaims; service stays responsive

  1-8 are implemented. 9-12 print what they would need and skip.

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)    IMPL="${2:?--impl needs a value}"; shift 2 ;;
    --observe) OBSERVE="${2:?--observe needs seconds}"; shift 2 ;;
    --rate)    LOAD_RATE="${2:?--rate needs a number}"; shift 2 ;;
    --no-load) NO_LOAD=1; shift ;;
    --list)    list_experiments; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*)        fail "unknown option: $1"; echo; usage; exit 2 ;;
    *)         [[ -z "${EXPERIMENT}" ]] && EXPERIMENT="$1" || { fail "unexpected argument: $1"; exit 2; }; shift ;;
  esac
done

if [[ -z "${EXPERIMENT}" ]]; then
  fail "which experiment? (1-12)"
  list_experiments
  exit 2
fi
[[ "${EXPERIMENT}" =~ ^[0-9]+$ ]] && (( EXPERIMENT >= 1 && EXPERIMENT <= 12 )) \
  || { fail "'${EXPERIMENT}' is not an experiment number (1-12)"; exit 2; }
is_impl "${IMPL}" || { fail "unknown implementation '${IMPL}' (expected: ${IMPLS_ALL[*]})"; exit 2; }
[[ "${OBSERVE}" =~ ^[0-9]+$ && "${OBSERVE}" -ge 5 ]] || { fail "--observe must be at least 5 seconds"; exit 2; }

require_docker

BASE="$(impl_base_url "${IMPL}")"
SVC="$(impl_service "${IMPL}")"
CONTAINER="$(impl_container "${IMPL}")"
TMP="$(mktemp -d)"

summary_reset

# ─────────────────────────────────────────────────────────────────────────────
# Restore — registered before the fault, run in reverse, always
# ─────────────────────────────────────────────────────────────────────────────
RESTORE=()
on_exit() {
  local i
  if (( ${#RESTORE[@]} )); then
    printf '\n' >&2
    info "restoring"
    for (( i = ${#RESTORE[@]} - 1; i >= 0; i-- )); do
      step "${RESTORE[$i]}"
      eval "${RESTORE[$i]}" >/dev/null 2>&1 || warn "restore step failed: ${RESTORE[$i]}"
    done
  fi
  stop_load
  rm -rf "${TMP}"
}
trap on_exit EXIT
trap 'printf "\n"; warn "interrupted"; exit 130' INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Background load
# ─────────────────────────────────────────────────────────────────────────────
K6_PID=""
stop_load() {
  [[ -n "${K6_PID}" ]] || return 0
  kill "${K6_PID}" 2>/dev/null || true
  wait "${K6_PID}" 2>/dev/null || true
  K6_PID=""
}

start_load() {
  (( NO_LOAD )) && { step "background load disabled (--no-load)"; return 0; }
  local seconds=$(( OBSERVE * 3 + 30 ))
  step "background load: ${LOAD_RATE} rps for up to ${seconds}s (open-loop)"
  (
    k6_run tests/load/mixed.js \
      -e "BASE_URL=${BASE}" \
      -e "RATE=${LOAD_RATE}" \
      -e "DURATION=${seconds}s" \
      -e "RESULTS_DIR=${TMP}" \
      -e "RUN_LABEL=chaos-${EXPERIMENT}" \
      --no-usage-report --quiet
  ) >"${TMP}/k6.log" 2>&1 &
  K6_PID=$!
  sleep 3
  if ! kill -0 "${K6_PID}" 2>/dev/null; then
    warn "the load generator exited immediately — continuing with probes only"
    tail -10 "${TMP}/k6.log" | sed 's/^/        /' >&2
    K6_PID=""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Probing
# ─────────────────────────────────────────────────────────────────────────────
TOKEN=""
get_token() {
  local email body
  email="chaos-$(date +%s)-${RANDOM}@taskflow.test"
  body="$(curl -sS --max-time 10 -X POST "${BASE}/api/v1/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"ChaosPass123\",\"displayName\":\"Chaos Bot\"}" \
    2>/dev/null || true)"
  TOKEN="$(printf '%s' "${body}" | jq -r '.data.tokens.accessToken // empty' 2>/dev/null || true)"
  [[ -n "${TOKEN}" ]] && step "acquired a token for authenticated probes"
}

# probe <url> <seconds> <outfile> [auth]
#
# Writes "<http_code> <seconds> <retry_after>" per line. Deliberately separate
# from k6: k6 reports percentiles over a window, and "was there ever a 5xx"
# is a question about individual requests.
probe() {
  local url="$1" seconds="$2" out="$3" auth="${4:-}"
  local deadline; deadline=$(( $(date +%s) + seconds ))
  local hdrfile="${out}.hdr" line ra
  : > "${out}"
  local -a hdr=()
  [[ -n "${auth}" && -n "${TOKEN}" ]] && hdr=(-H "Authorization: Bearer ${TOKEN}")
  while (( $(date +%s) < deadline )); do
    # Headers to a file, not into -w: %{header_json} is multi-line, and
    # appending it to the same line turns one probe into six records and every
    # count below into fiction.
    line="$(curl -sS -o /dev/null -D "${hdrfile}" --max-time 5 \
      -w '%{http_code} %{time_total}' "${hdr[@]}" "${url}" 2>/dev/null)"
    [[ -z "${line}" ]] && line="000 0"
    ra="$(tr -d '\r' < "${hdrfile}" 2>/dev/null \
      | sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*//p' | head -1)"
    printf '%s %s\n' "${line}" "${ra:--}" >> "${out}"
    sleep "${PROBE_INTERVAL}"
  done
}

# Counters over a probe file.
count_all()    { wc -l < "$1" | tr -d ' '; }
count_status() { awk -v p="$2" '$1 ~ "^"p {n++} END {print n+0}' "$1"; }
count_exact()  { awk -v c="$2" '$1 == c {n++} END {print n+0}' "$1"; }
pct_of()       { awk -v a="$1" -v b="$2" 'BEGIN { if (b+0 == 0) print "0.0"; else printf "%.1f", 100*a/b }'; }
p95_ms()       { awk '{print $2*1000}' "$1" | sort -g | awk '{a[NR]=$1} END { if (NR==0) {print "—"; exit} printf "%.0f", a[int(NR*0.95+0.5) < 1 ? 1 : int(NR*0.95+0.5)] }'; }
any_retry_after() { awk '$3 != "-" {print $3; exit}' "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Assertions
# ─────────────────────────────────────────────────────────────────────────────
assert() { # <0|1 pass> <label> <observed>
  if (( $1 == 0 )); then
    ok "${2}"
    step "observed: ${3}"
    summary_add "${2}" PASS "${3}"
  else
    fail "${2}"
    step "observed: ${3}"
    summary_add "${2}" FAIL "${3}"
  fi
}

# Something we could not measure — an absent metric is not a failed assertion,
# it is an unbuilt phase, and conflating the two makes the report useless.
unobservable() { # <label> <why>
  warn "${1}: not observable"
  step "${2}"
  summary_add "${1}" SKIP "${2}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Faults
# ─────────────────────────────────────────────────────────────────────────────
require_container() { # <container> <friendly> <hint>
  container_running "$1" && return 0
  die_hint "$2 is not running (container $1)" "$3"
}

stop_service() { # <compose service> <container>
  step "docker compose stop $1"
  compose -f docker-compose.yml -f docker-compose.infra.yml -f docker-compose.observability.yml \
    stop "$1" >/dev/null 2>&1 || docker stop "$2" >/dev/null 2>&1
  RESTORE+=("docker start $2")
}

# Sets NETEM_ERROR on failure so the caller can say WHY rather than guessing.
NETEM_ERROR=""
netem_apply() { # <container> <delay>
  NETEM_ERROR=""
  if ! ensure_image "${NETSHOOT_IMAGE}"; then
    NETEM_ERROR="could not pull ${NETSHOOT_IMAGE}"
    return 1
  fi
  step "tc qdisc add dev eth0 root netem delay $2 (on $1)"
  local err
  if ! err="$(docker run --rm --net="container:$1" --cap-add=NET_ADMIN "${NETSHOOT_IMAGE}" \
      tc qdisc add dev eth0 root netem delay "$2" 2>&1)"; then
    # "Specified qdisc kind is unknown" is not a permissions problem: it means
    # the host kernel has no sch_netem module. Common on minimal kernels,
    # microVMs (Firecracker) and most managed CI runners. Saying "needs
    # NET_ADMIN" there sends you looking in the wrong place.
    if [[ "${err}" == *"qdisc kind is unknown"* ]]; then
      NETEM_ERROR="the host kernel has no sch_netem module (try: sudo modprobe sch_netem)"
    else
      NETEM_ERROR="tc failed: ${err//$'\n'/ }"
    fi
    return 1
  fi
  RESTORE+=("docker run --rm --net=container:$1 --cap-add=NET_ADMIN ${NETSHOOT_IMAGE} tc qdisc del dev eth0 root")
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight common to every implemented experiment
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
  if [[ "$(http_status "${BASE}/api/v1/health/live" 3)" != "200" ]]; then
    die_hint "${IMPL} is not answering at ${BASE}" \
      "Start it:  docker compose up -d ${SVC}   (or make up)" \
      "A chaos experiment against a service that is already down measures nothing."
  fi
  if service_is_501 "${BASE}"; then
    warn "${IMPL} returns 501 — the Phase 0 skeleton is still mounted"
    step "Health probes are real, so experiments 3 and 6 still say something."
    step "Everything about breakers, fallbacks and the outbox needs Phase 4-6."
  fi
  get_token
}

baseline() { # <seconds> — what "normal" looks like, so the fault has a comparison
  local secs="${1:-8}"
  step "baseline: ${secs}s before the fault"
  probe "${BASE}/api/v1/tasks" "${secs}" "${TMP}/baseline.txt" auth
  local n; n="$(count_all "${TMP}/baseline.txt")"
  step "baseline: ${n} probes, 2xx=$(count_status "${TMP}/baseline.txt" 2), 5xx=$(count_status "${TMP}/baseline.txt" 5), p95=$(p95_ms "${TMP}/baseline.txt")ms"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Cache down
# ─────────────────────────────────────────────────────────────────────────────
exp1() {
  section "Experiment 1 — cache down"
  info "expected: 200s continue, latency rises, breaker opens, ZERO 5xx"
  printf '      %sA cache is an optimisation. A service that returns 500 when its cache%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sis unavailable has made the optimisation load-bearing.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  require_container "${VALKEY_CONTAINER}" "valkey" "Start it:  docker compose up -d valkey"
  preflight
  start_load
  baseline 8
  local base_p95; base_p95="$(p95_ms "${TMP}/baseline.txt")"

  stop_service valkey "${VALKEY_CONTAINER}"
  probe "${BASE}/api/v1/tasks" "${OBSERVE}" "${TMP}/fault.txt" auth

  local total ok2xx s5xx p95
  total="$(count_all "${TMP}/fault.txt")"
  ok2xx="$(count_status "${TMP}/fault.txt" 2)"
  s5xx="$(count_status "${TMP}/fault.txt" 5)"
  p95="$(p95_ms "${TMP}/fault.txt")"

  assert "$( (( s5xx == 0 )) && echo 0 || echo 1 )" \
    "zero 5xx while the cache is down" \
    "${s5xx} of ${total} probes returned 5xx"
  assert "$( (( ok2xx > total / 2 )) && echo 0 || echo 1 )" \
    "requests keep succeeding from the database" \
    "${ok2xx}/${total} 2xx ($(pct_of "${ok2xx}" "${total}")%)"

  local breaker
  breaker="$(scrape_metric_sum "${BASE}" circuit_breaker_state 2>/dev/null || true)"
  if [[ -z "${breaker}" ]]; then
    unobservable "cache circuit breaker opened" \
      "no circuit_breaker_state metric on ${BASE}/metrics — Phase 5 not built yet"
  else
    assert 0 "cache circuit breaker is observable" "circuit_breaker_state sum=${breaker}"
  fi
  step "latency p95: ${base_p95}ms before → ${p95}ms during (a rise is expected and correct)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Cache slow
# ─────────────────────────────────────────────────────────────────────────────
exp2() {
  section "Experiment 2 — cache slow (500ms added latency)"
  info "expected: the 200ms command timeout trips and the request falls through to the DB"
  printf '      %sA slow dependency is worse than a dead one: a dead one fails fast,%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sa slow one holds your connections and drags you down with it.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  require_container "${VALKEY_CONTAINER}" "valkey" "Start it:  docker compose up -d valkey"
  preflight
  netem_apply "${VALKEY_CONTAINER}" 500ms || {
    unobservable "cache slow" "no packet delay could be applied — ${NETEM_ERROR}"
    return 0
  }
  start_load
  probe "${BASE}/api/v1/tasks" "${OBSERVE}" "${TMP}/fault.txt" auth

  local total ok2xx s5xx p95
  total="$(count_all "${TMP}/fault.txt")"; ok2xx="$(count_status "${TMP}/fault.txt" 2)"
  s5xx="$(count_status "${TMP}/fault.txt" 5)"; p95="$(p95_ms "${TMP}/fault.txt")"

  assert "$( (( s5xx == 0 )) && echo 0 || echo 1 )" \
    "no 5xx while the cache is slow" "${s5xx} of ${total} probes returned 5xx"
  # The point of a 200ms command timeout is that the request does NOT wait
  # 500ms for the cache. If p95 is above ~700ms the timeout is not being
  # applied and the cache latency is passing straight through to the user.
  assert "$( awk -v p="${p95}" 'BEGIN { exit !(p+0 < 700) }' && echo 0 || echo 1 )" \
    "the 500ms cache delay does not reach the user" \
    "p95 ${p95}ms (a 200ms timeout plus a DB read should stay well under 700ms)"
  step "${ok2xx}/${total} succeeded ($(pct_of "${ok2xx}" "${total}")%)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. DB DOWN — the acid test
# ─────────────────────────────────────────────────────────────────────────────
exp3() {
  section "Experiment 3 — DATABASE DOWN"
  printf '\n' >&2
  printf '  %s%s%s\n' "${C_BOLD}" "  THIS IS THE ONE THAT MATTERS." "${C_RESET}" >&2
  printf '\n' >&2
  printf '  %sliveness  = "is this process wedged?"   Answer: no. It must stay 200.%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '  %sreadiness = "should I get traffic?"     Answer: no. It must go 503.%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '\n' >&2
  printf '  %sIf liveness checks the database, Kubernetes kills every replica —%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '  %sall of them healthy — during a blip the database would have survived.%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '  %sYou then get a cold-start stampede against a database that has only%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '  %sjust come back. A 30-second failover becomes a 20-minute outage.%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '\n' >&2

  require_container "${PG_CONTAINER}" "postgres" "Start it:  make up"
  preflight
  (( NO_LOAD )) || start_load

  stop_service postgres "${PG_CONTAINER}"

  # Readiness can legitimately take a probe interval or two to notice.
  step "waiting up to 15s for readiness to react"
  local waited=0
  while (( waited < 15 )); do
    [[ "$(http_status "${BASE}/api/v1/health/ready" 3)" != "200" ]] && break
    sleep 1; waited=$(( waited + 1 ))
  done
  step "readiness changed after ~${waited}s"

  probe "${BASE}/api/v1/health/live"  "${OBSERVE}" "${TMP}/live.txt"  &
  local p1=$!
  probe "${BASE}/api/v1/health/ready" "${OBSERVE}" "${TMP}/ready.txt" &
  local p2=$!
  probe "${BASE}/api/v1/tasks"        "${OBSERVE}" "${TMP}/tasks.txt" auth
  wait "${p1}" "${p2}" 2>/dev/null || true

  local live_n live_200 ready_n ready_503 ready_200 tasks_n tasks_503 tasks_5xx retry
  live_n="$(count_all "${TMP}/live.txt")";   live_200="$(count_exact "${TMP}/live.txt" 200)"
  ready_n="$(count_all "${TMP}/ready.txt")"; ready_503="$(count_exact "${TMP}/ready.txt" 503)"
  ready_200="$(count_exact "${TMP}/ready.txt" 200)"
  tasks_n="$(count_all "${TMP}/tasks.txt")"; tasks_503="$(count_exact "${TMP}/tasks.txt" 503)"
  tasks_5xx="$(count_status "${TMP}/tasks.txt" 5)"
  retry="$(any_retry_after "${TMP}/tasks.txt")"

  printf '\n' >&2

  # ── the assertion the whole document exists for ──
  if (( live_200 == live_n && live_n > 0 )); then
    ok "LIVENESS STAYED UP — ${live_200}/${live_n} probes returned 200"
    step "Correct. The process is not wedged, so nothing should restart it."
    summary_add "liveness stays 200 while the DB is down" PASS "${live_200}/${live_n} were 200"
  else
    fail "LIVENESS FAILED WHILE THE DATABASE WAS DOWN"
    printf '\n' >&2
    printf '  %s%s%s\n' "${C_RED}${C_BOLD}" "  THIS IS THE BUG THIS EXPERIMENT EXISTS TO FIND." "${C_RESET}" >&2
    printf '\n' >&2
    printf '  %sOnly %s of %s liveness probes returned 200.%s\n' "${C_DIM}" "${live_200}" "${live_n}" "${C_RESET}" >&2
    printf '  %s/health/live is checking the database. It must not.%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '  %sLiveness answers one question: is this process able to make progress?%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '  %sA process waiting for a database is making progress. Kill it and you%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '  %shave turned a recoverable dependency blip into a total outage, with%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '  %severy replica cold-starting into a database that is barely back.%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '\n' >&2
    printf '  %sFix: /health/live must touch nothing external. See the resilience%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '  %sspec §12 and the OBS5 health-probe table in docs/openapi.yaml.%s\n' "${C_DIM}" "${C_RESET}" >&2
    printf '\n' >&2
    summary_add "liveness stays 200 while the DB is down" FAIL "only ${live_200}/${live_n} were 200"
  fi

  assert "$( (( ready_503 > 0 && ready_200 == 0 )) && echo 0 || echo 1 )" \
    "readiness fails while the DB is down" \
    "${ready_503}/${ready_n} were 503, ${ready_200} still said 200"

  assert "$( (( tasks_503 > 0 )) && echo 0 || echo 1 )" \
    "the API returns 503 rather than 500" \
    "${tasks_503}/${tasks_n} were 503 (${tasks_5xx} 5xx in total)"

  if [[ -n "${retry}" ]]; then
    assert 0 "Retry-After is present on the 503" "Retry-After: ${retry}"
  else
    assert 1 "Retry-After is present on the 503" \
      "no Retry-After header — clients cannot tell a retryable outage from a permanent one, so they all retry immediately and together"
  fi

  # ── recovery ──
  printf '\n' >&2
  info "restarting the database and watching it come back"
  docker start "${PG_CONTAINER}" >/dev/null 2>&1 || true
  local back=0 t=0
  while (( t < 90 )); do
    [[ "$(http_status "${BASE}/api/v1/health/ready" 3)" == "200" ]] && { back="${t}"; break; }
    sleep 2; t=$(( t + 2 ))
  done
  if (( t < 90 )); then
    assert 0 "readiness recovers by itself" "back to 200 ~${back}s after the database returned"
  else
    assert 1 "readiness recovers by itself" \
      "still not ready 90s after the database came back — a stuck connection pool needs a restart, which is exactly what you did not want to need"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. DB slow
# ─────────────────────────────────────────────────────────────────────────────
exp4() {
  section "Experiment 4 — DB slow (2s added latency)"
  info "expected: the pool saturates; pending-requests rises BEFORE latency does"
  printf '      %sThat ordering is the point. Queue depth is a leading indicator and%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %slatency is a lagging one; alerting on latency alone means you find%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sout after the users do.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  require_container "${PG_CONTAINER}" "postgres" "Start it:  make up"
  preflight

  local pending_before
  pending_before="$(scrape_metric_sum "${BASE}" db_client_connection_pending_requests 2>/dev/null || true)"

  netem_apply "${PG_CONTAINER}" 2s || {
    unobservable "DB slow" "no packet delay could be applied — ${NETEM_ERROR}"
    return 0
  }
  start_load
  probe "${BASE}/api/v1/tasks" "${OBSERVE}" "${TMP}/fault.txt" auth

  local total s5xx s503 p95
  total="$(count_all "${TMP}/fault.txt")"; s5xx="$(count_status "${TMP}/fault.txt" 5)"
  s503="$(count_exact "${TMP}/fault.txt" 503)"; p95="$(p95_ms "${TMP}/fault.txt")"

  local pending_after
  pending_after="$(scrape_metric_sum "${BASE}" db_client_connection_pending_requests 2>/dev/null || true)"

  if [[ -z "${pending_before}${pending_after}" ]]; then
    unobservable "pending DB requests rise" \
      "no db_client_connection_pending_requests metric — Phase 2/3 not built yet"
  else
    assert "$( awk -v a="${pending_before:-0}" -v b="${pending_after:-0}" 'BEGIN { exit !(b+0 > a+0) }' && echo 0 || echo 1 )" \
      "pending DB requests rise under a slow database" \
      "${pending_before:-0} → ${pending_after:-0} waiters"
  fi

  # A 2s database with a 2s acquire timeout and a 5s statement timeout should
  # produce shed load (503/504), not 500s and not unbounded waits.
  assert "$( (( s5xx == s503 )) && echo 0 || echo 1 )" \
    "overload is shed as 503, not crashed as 500" \
    "${s503} 503 of ${s5xx} 5xx across ${total} probes"
  step "p95 during the fault: ${p95}ms"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Broker down
# ─────────────────────────────────────────────────────────────────────────────
exp5() {
  section "Experiment 5 — broker down (Kafka appendix only)"
  info "expected: writes still succeed; the outbox backlog climbs; it drains on restart"
  printf '      %sThis is what the transactional outbox buys you: the event is a row%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sin the same transaction as the write, so the transport being down%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %scannot fail a user request and cannot lose an event.%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sOn the default Streams transport the same property is experiment 1%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %s(cache down) plus `pytest -m phase6 -k valkey_stopped`.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  if ! container_running taskflow-redpanda; then
    warn "redpanda is not running — it is behind the \`kafka\` compose profile (spec §4.9)"
    step "Start it:  docker compose -f docker-compose.infra.yml --profile kafka up -d redpanda"
    summary_add "broker down" SKIP "redpanda not running (kafka profile)"
    return 0
  fi
  preflight
  start_load
  stop_service redpanda taskflow-redpanda

  # Writes, not reads: the outbox only matters on the write path.
  local created=0 failed=0 i code
  step "creating tasks while the broker is down"
  for i in $(seq 1 "${OBSERVE}"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -X POST "${BASE}/api/v1/tasks" \
      -H 'Content-Type: application/json' \
      ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
      -d "{\"title\":\"chaos-broker-${i}\"}" 2>/dev/null || echo 000)"
    if [[ "${code}" =~ ^2 ]]; then created=$(( created + 1 )); else failed=$(( failed + 1 )); fi
    sleep 1
  done

  assert "$( (( created > 0 && failed == 0 )) && echo 0 || echo 1 )" \
    "writes succeed while the broker is down" \
    "${created} created, ${failed} failed"

  local pending
  pending="$(psql_q "SELECT count(*) FROM outbox WHERE published_at IS NULL" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "${pending}" ]]; then
    pending="$(scrape_metric_sum "${BASE}" outbox_pending_events 2>/dev/null || true)"
  fi
  if [[ -z "${pending}" ]]; then
    unobservable "outbox backlog climbs" \
      "no outbox table and no outbox_pending_events metric — Phase 6 not built yet"
  else
    assert "$( awk -v p="${pending}" 'BEGIN { exit !(p+0 > 0) }' && echo 0 || echo 1 )" \
      "the outbox backlog climbs" "${pending} unpublished event(s) waiting"
  fi

  info "restarting the broker and watching the backlog drain"
  docker start taskflow-redpanda >/dev/null 2>&1 || true
  sleep 20
  local drained
  drained="$(psql_q "SELECT count(*) FROM outbox WHERE published_at IS NULL" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "${drained}" ]]; then
    unobservable "the backlog drains on restart" "no outbox table to read"
  else
    assert "$( awk -v a="${pending:-0}" -v b="${drained}" 'BEGIN { exit !(b+0 < a+0) }' && echo 0 || echo 1 )" \
      "the backlog drains once the broker returns" "${pending} → ${drained} pending"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Collector down
# ─────────────────────────────────────────────────────────────────────────────
exp6() {
  section "Experiment 6 — telemetry collector down"
  info "expected: NO user-visible impact at all"
  printf '      %sThe most commonly violated one. A blocking OTLP export, or an%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sunbounded span queue, turns your observability stack into a hard%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sdependency of your API — and you find out when the collector is%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sredeployed at 2am and takes the service with it.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  if ! container_running taskflow-otelcol; then
    warn "the collector is not running — nothing to break"
    step "Start the observability stack:  make up-full"
    summary_add "collector down" SKIP "otel-collector not running"
    return 0
  fi
  preflight
  start_load
  baseline 10
  local base_p95 base_5xx
  base_p95="$(p95_ms "${TMP}/baseline.txt")"
  base_5xx="$(count_status "${TMP}/baseline.txt" 5)"

  stop_service otel-collector taskflow-otelcol
  probe "${BASE}/api/v1/tasks" "${OBSERVE}" "${TMP}/fault.txt" auth

  local total s5xx p95
  total="$(count_all "${TMP}/fault.txt")"; s5xx="$(count_status "${TMP}/fault.txt" 5)"
  p95="$(p95_ms "${TMP}/fault.txt")"

  assert "$( (( s5xx <= base_5xx )) && echo 0 || echo 1 )" \
    "no errors introduced by losing the collector" \
    "${s5xx} 5xx of ${total} (baseline ${base_5xx})"
  # 50% is generous on purpose: on a small sample p95 is noisy. Anything close
  # to the 5s or 10s OTLP export timeout would blow straight past it.
  assert "$( awk -v a="${base_p95}" -v b="${p95}" 'BEGIN { exit !(b+0 <= a+0*1.5 + 50) }' && echo 0 || echo 1 )" \
    "latency is unaffected by losing the collector" \
    "p95 ${base_p95}ms → ${p95}ms"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Storage down
# ─────────────────────────────────────────────────────────────────────────────
exp7() {
  section "Experiment 7 — object storage down"
  info "expected: attachment endpoints 503; task endpoints completely unaffected"
  printf '      %sBulkheading. One failed dependency should cost you the features that%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sneed it and nothing else.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  if ! container_running taskflow-s3; then
    warn "SeaweedFS is not running — nothing to break"
    step "Start it:  docker compose -f docker-compose.yml -f docker-compose.infra.yml up -d seaweedfs"
    summary_add "storage down" SKIP "seaweedfs not running"
    return 0
  fi
  preflight
  start_load
  stop_service seaweedfs taskflow-s3

  probe "${BASE}/api/v1/tasks" "${OBSERVE}" "${TMP}/tasks.txt" auth &
  local p1=$!
  # A task id is needed for the attachment path; any id will do, because the
  # question is which failure mode the endpoint chooses, not whether the task
  # exists. 404 would also be an acceptable answer and is counted as such.
  probe "${BASE}/api/v1/tasks/00000000-0000-0000-0000-000000000000/attachments" \
    "${OBSERVE}" "${TMP}/att.txt" auth
  wait "${p1}" 2>/dev/null || true

  local t_n t_2xx t_5xx a_n a_503 a_5xx a_404
  t_n="$(count_all "${TMP}/tasks.txt")"; t_2xx="$(count_status "${TMP}/tasks.txt" 2)"
  t_5xx="$(count_status "${TMP}/tasks.txt" 5)"
  a_n="$(count_all "${TMP}/att.txt")"; a_503="$(count_exact "${TMP}/att.txt" 503)"
  a_5xx="$(count_status "${TMP}/att.txt" 5)"; a_404="$(count_exact "${TMP}/att.txt" 404)"

  assert "$( (( t_5xx == 0 )) && echo 0 || echo 1 )" \
    "tasks are unaffected by storage being down" \
    "${t_2xx}/${t_n} 2xx, ${t_5xx} 5xx on /tasks"
  if (( a_5xx == 0 && a_404 == a_n )); then
    unobservable "attachments degrade to 503" \
      "every attachment probe returned 404 — Phase 11 is not built, so there is nothing to degrade"
  else
    assert "$( (( a_503 == a_5xx )) && echo 0 || echo 1 )" \
      "attachments degrade to 503, not 500" \
      "${a_503} 503 of ${a_5xx} 5xx across ${a_n} probes"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. SIGTERM mid-request
# ─────────────────────────────────────────────────────────────────────────────
exp8() {
  section "Experiment 8 — SIGTERM a replica mid-request"
  info "expected: ZERO dropped requests; WebSocket clients close with 1001"
  printf '      %sGraceful shutdown is the difference between a deploy nobody notices%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sand a deploy that drops a slice of traffic every single time. You%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '      %sdeploy far more often than your database fails.%s\n\n' "${C_DIM}" "${C_RESET}" >&2

  require_container "${CONTAINER}" "${IMPL}" "Start it:  docker compose up -d ${SVC}"
  preflight
  start_load

  # Probe hard across the signal so the shutdown window is densely sampled —
  # graceful shutdown failures are a handful of requests wide.
  PROBE_INTERVAL="0.2"
  probe "${BASE}/api/v1/tasks" "$(( OBSERVE + 10 ))" "${TMP}/shutdown.txt" auth &
  local pp=$!

  sleep 5
  step "docker kill --signal=SIGTERM ${CONTAINER}"
  docker kill --signal=SIGTERM "${CONTAINER}" >/dev/null 2>&1 || true
  RESTORE+=("docker start ${CONTAINER}")

  wait "${pp}" 2>/dev/null || true
  PROBE_INTERVAL="0.5"

  # Everything up to the moment the listener closes must be answered cleanly.
  # Connection refused (000) AFTER it closes is correct — that replica is gone
  # and a load balancer would have stopped sending to it. 5xx is never correct.
  local total s5xx refused pre_refusal_5xx
  total="$(count_all "${TMP}/shutdown.txt")"
  s5xx="$(count_status "${TMP}/shutdown.txt" 5)"
  refused="$(count_exact "${TMP}/shutdown.txt" 000)"
  pre_refusal_5xx="$(awk '$1 == "000" {exit} $1 ~ /^5/ {n++} END {print n+0}' "${TMP}/shutdown.txt")"

  assert "$( (( pre_refusal_5xx == 0 )) && echo 0 || echo 1 )" \
    "no request was dropped before the listener closed" \
    "${pre_refusal_5xx} 5xx before the first refused connection (${s5xx} 5xx overall, ${refused} refused of ${total})"

  local drain
  drain="$(awk 'BEGIN{n=0} $1 == "000" {print NR; exit}' "${TMP}/shutdown.txt")"
  if [[ -n "${drain}" ]]; then
    step "the listener stopped accepting at probe ${drain} of ${total} (~$(awk -v d="${drain}" 'BEGIN{printf "%.1f", d*0.2}')s in)"
  else
    step "the listener never stopped accepting within the window"
  fi

  unobservable "WebSocket clients receive close code 1001" \
    "not probed here — needs a WebSocket client; tests/conformance/test_phase10_realtime.py covers it"

  info "bringing the container back"
  docker start "${CONTAINER}" >/dev/null 2>&1 || true
  if wait_for_health "${BASE}" 90; then
    assert 0 "the replica comes back healthy" "ready again within 90s"
  else
    assert 1 "the replica comes back healthy" "still not ready 90s after restart"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 9-12 — described, not run
# ─────────────────────────────────────────────────────────────────────────────
not_implemented() { # <n> <title> <what it needs...>
  local n="$1" title="$2"; shift 2
  section "Experiment ${n} — ${title}"
  warn "not implemented by this script"
  printf '\n  %sWhat it would need:%s\n' "${C_BOLD}" "${C_RESET}" >&2
  local l
  for l in "$@"; do printf '    %s\n' "${l}" >&2; done
  printf '\n' >&2
  summary_add "experiment ${n}" SKIP "not implemented — see the notes above"
}

exp9() {
  not_implemented 9 "Traffic 10x" \
    "A measured capacity number to be 10x OF. Run the sweep first:" \
    "  scripts/benchmark.sh --impl ${IMPL} --scenario capacity" \
    "Then a k6 ramping-arrival-rate stage to 10x that, and two separate" \
    "latency series: one for SERVED requests and one for SHED requests." \
    "" \
    "The assertion is subtle enough to be worth doing by hand: p99 for served" \
    "requests must stay bounded while shedding is active. Mixing shed and" \
    "served requests into one histogram makes a correctly-shedding service" \
    "look broken and a broken one look fine, because a fast 503 improves the" \
    "percentile."
}

exp10() {
  not_implemented 10 "Poison message" \
    "A Kafka producer to put malformed JSON on taskflow.task-events:" \
    "  docker exec -i taskflow-redpanda rpk topic produce taskflow.task-events" \
    "Then assert two things:" \
    "  1. the message lands on taskflow.task-events.dlq" \
    "  2. the consumer group's lag on that partition keeps FALLING" \
    "" \
    "(2) is the real test. A consumer that retries a poison message forever" \
    "does not crash and does not alert — it just silently stops the partition," \
    "and every well-formed message behind it waits with it. Needs Phase 6."
}

exp11() {
  not_implemented 11 "Clock skew" \
    "Skew one container's clock by 5 minutes. Containers share the host's" \
    "clock, so this needs either:" \
    "  • libfaketime injected via LD_PRELOAD into the service container, or" \
    "  • --cap-add SYS_TIME plus a container-private time namespace" \
    "Neither is available with the default runtime, which is why it is not" \
    "automated here." \
    "" \
    "Then assert: a token issued by the skewed replica is accepted by the" \
    "others (JWT nbf/exp leeway), and record what the rate limiter does —" \
    "GCRA works in absolute time, so skew moves a client's allowance."
}

exp12() {
  not_implemented 12 "Connection exhaustion" \
    "Open 500 idle TCP connections and hold them:" \
    "  for i in \$(seq 500); do (exec 3<>/dev/tcp/localhost/$(impl_port "${IMPL}"); sleep 300) & done" \
    "Then assert:" \
    "  • the service still answers /health/live promptly" \
    "  • idle connections are reclaimed by the server's idle timeout" \
    "  • MAX_CONCURRENT_REQUESTS bounds in-flight work, not connections" \
    "" \
    "Not automated because 500 held file descriptors on the host is a fine" \
    "way to wedge the machine you are testing from — the load generator and" \
    "the service share a kernel here."
}

# ─────────────────────────────────────────────────────────────────────────────
printf '\n' >&2
info "implementation ${IMPL} @ ${BASE}"
info "observation window ${OBSERVE}s"

"exp${EXPERIMENT}"

summary_print "chaos ${EXPERIMENT}"

FAILED="$(summary_count FAIL)"
PASSED="$(summary_count PASS)"
SKIPPED="$(summary_count SKIP)"

if (( FAILED > 0 )); then
  fail "experiment ${EXPERIMENT}: ${FAILED} assertion(s) FAILED (${PASSED} passed, ${SKIPPED} not observable)"
  exit 1
fi
if (( PASSED == 0 )); then
  warn "experiment ${EXPERIMENT}: nothing was asserted (${SKIPPED} not observable)"
  exit 0
fi
ok "experiment ${EXPERIMENT}: all ${PASSED} assertion(s) held (${SKIPPED} not observable)"
exit 0
