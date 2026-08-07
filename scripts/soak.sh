#!/usr/bin/env bash
#
# soak.sh — one hour at 60% of the knee rate, watching for leaks.
#
# This is the only test in the suite that finds a slow leak, and slow leaks are
# the ones that matter: a five-minute run shows a perfectly healthy service,
# and the same service falls over on a Thursday after four days of uptime. By
# then the deploy that introduced it is a fortnight back and nobody connects
# the two.
#
# WHAT IS SAMPLED, every 30 seconds
#   RSS               the container's resident memory
#   open FDs          sockets and files held by the process
#   DB connections    rows in pg_stat_activity for this database
#
# HOW A LEAK IS CALLED
#   Least-squares fit over the samples. A positive slope alone is not enough —
#   a healthy heap sawtooths, and a sawtooth sampled over an hour has a slope
#   too. The verdict needs a positive slope AND R² > 0.7, i.e. the metric is
#   not just higher at the end but has been climbing steadily the whole way.
#   That combination is what distinguishes "the floor keeps rising" from "it
#   goes up and down".
#
# WHY 60% OF THE KNEE
#   At the knee, queueing dominates and every metric climbs for reasons that
#   are not leaks. Well under it, the service is comfortable and anything that
#   grows monotonically is growing because of the code.
#
#   scripts/soak.sh --impl go
#   scripts/soak.sh --impl rust --duration 15m --knee-rate 2400
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Keys its per-implementation results in an associative array.
require_bash4

IMPL_ARG="go"
DURATION="1h"
KNEE_RATE="${KNEE_RATE:-1000}"
FRACTION="0.6"
INTERVAL=30
OUT_BASE="benchmarks/results"
R2_THRESHOLD="0.7"

usage() {
  cat <<'EOF'
soak.sh — long-duration leak hunt

USAGE
  scripts/soak.sh [--impl <lang>] [--duration 1h] [--knee-rate N]

OPTIONS
  --impl <lang>     go | rust | python | csharp | typescript | all
                    or a comma-separated list                  (default go)
                    "all" soaks them one after another, so budget five times
                    the duration — soaking them at the same time would have
                    them competing for the host and the database, and every
                    metric would then be measuring the contention
  --duration D      1h, 90m, 45s or a number of seconds        (default 1h)
  --knee-rate N     arrival rate at which p99 leaves the floor (default 1000)
                    Get the real number from the capacity sweep:
                      scripts/benchmark.sh --impl go --scenario capacity
  --fraction F      fraction of the knee to soak at            (default 0.6)
  --interval N      seconds between samples                    (default 30)
  --r2 F            R² above which a positive slope is a leak  (default 0.7)
  --out DIR         output base directory        (default benchmarks/results)
  -h, --help

OUTPUT  (benchmarks/results/<ts>/)
  soak-<impl>.csv   one row per sample: elapsed, rss, fds, db connections, cpu
  soak-<impl>.md    the trend analysis and the verdict

READING THE RESULT
  A leak is a metric with a positive slope and a good fit. The CSV is there so
  you can plot it — the number that convinces anyone is the graph, and an hour
  of samples is enough to draw one.

  Sawtooth RSS is garbage collection and is fine. RSS whose LOW POINTS keep
  rising is not.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)      IMPL_ARG="${2:?--impl needs a value}"; shift 2 ;;
    --duration)  DURATION="${2:?--duration needs a value}"; shift 2 ;;
    --knee-rate) KNEE_RATE="${2:?--knee-rate needs a number}"; shift 2 ;;
    --fraction)  FRACTION="${2:?--fraction needs a number}"; shift 2 ;;
    --interval)  INTERVAL="${2:?--interval needs a number}"; shift 2 ;;
    --r2)        R2_THRESHOLD="${2:?--r2 needs a number}"; shift 2 ;;
    --out)       OUT_BASE="${2:?--out needs a directory}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

# "all", "go", or "go,rust" — same spelling as benchmark.sh and profile.sh,
# because `make soak` passes IMPL=all by default and a script that only
# accepted one language would fail on the command the Makefile actually runs.
IMPLS=()
if [[ "${IMPL_ARG}" == "all" ]]; then
  IMPLS=("${IMPLS_ALL[@]}")
else
  IFS=',' read -r -a IMPLS <<<"${IMPL_ARG}"
  for i in "${IMPLS[@]}"; do
    is_impl "${i}" || { fail "unknown implementation '${i}' (expected: ${IMPLS_ALL[*]}, all)"; exit 2; }
  done
fi
(( ${#IMPLS[@]} )) || { fail "--impl selected nothing"; exit 2; }

DURATION_S="$(parse_duration_seconds "${DURATION}")" \
  || { fail "--duration '${DURATION}' is not a duration (try 1h, 90m, 45s or 3600)"; exit 2; }
(( DURATION_S > 0 )) || { fail "--duration must be positive"; exit 2; }
[[ "${INTERVAL}" =~ ^[0-9]+$ && "${INTERVAL}" -ge 1 ]] || { fail "--interval must be a positive integer"; exit 2; }
[[ "${KNEE_RATE}" =~ ^[0-9]+$ && "${KNEE_RATE}" -ge 1 ]] || { fail "--knee-rate must be a positive integer"; exit 2; }

RATE="$(awk -v k="${KNEE_RATE}" -v f="${FRACTION}" 'BEGIN { r = int(k*f + 0.5); if (r < 1) r = 1; print r }')"
EXPECTED_SAMPLES=$(( DURATION_S / INTERVAL ))

require_docker
detect_k6

TS="$(timestamp)"
OUT_DIR="${REPO_ROOT}/${OUT_BASE}/${TS}"
mkdir -p "${OUT_DIR}"
capture_environment "${OUT_DIR}/environment.txt"

section "soak"
info "implementations  ${IMPLS[*]}"
info "duration         ${DURATION} (${DURATION_S}s) each"
info "rate             ${RATE} rps  = ${FRACTION} x knee ${KNEE_RATE}"
info "sampling         every ${INTERVAL}s → ~${EXPECTED_SAMPLES} samples"
info "output           ${OUT_BASE}/${TS}"

if (( ${#IMPLS[@]} > 1 )); then
  warn "${#IMPLS[@]} implementations, one after another — about $(( DURATION_S * ${#IMPLS[@]} / 60 )) minutes in total"
  step "Sequential on purpose. Soaking them simultaneously would have them"
  step "competing for the host's CPU and for the same database, and the"
  step "resulting numbers would describe the contention, not the code."
fi

# Nine samples is not a trend. Say so before the hour is spent, not after.
if (( EXPECTED_SAMPLES < 10 )); then
  warn "only ~${EXPECTED_SAMPLES} samples per run — a regression over that few points means little"
  step "Use a longer --duration or a shorter --interval for a real verdict."
fi

if ! pg_ready; then
  warn "cannot reach Postgres — the connection-count column will be blank"
  step "That is the column that finds a connection leak, which is the most"
  step "common kind of leak. Start the database:  make up"
fi

SEED_ARG="$(seed_manifest_arg)"

# ─────────────────────────────────────────────────────────────────────────────
# Load generator lifecycle
# ─────────────────────────────────────────────────────────────────────────────
K6_PID=""
stop_load() {
  [[ -n "${K6_PID}" ]] || return 0
  kill "${K6_PID}" 2>/dev/null || true
  wait "${K6_PID}" 2>/dev/null || true
  K6_PID=""
}
trap 'printf "\n"; warn "interrupted — stopping the load generator"; stop_load; exit 130' INT TERM

pg_connection_count() {
  psql_q "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()" 2>/dev/null \
    | tr -d '[:space:]'
}

# ─────────────────────────────────────────────────────────────────────────────
# Trend analysis
# ─────────────────────────────────────────────────────────────────────────────
#
# column: 3 = rss, 4 = fds, 5 = db connections.
# Returns "slope intercept r2 n first last", slope in units per SECOND.
trend() {
  local col="$1" series
  series="$(awk -F, -v c="${col}" 'NR>1 && $c != "" && $c+0 == $c { print $1, $c }' "${CSV}")"
  [[ -z "${series}" ]] && { printf '0 0 0 0 — —'; return; }
  local fit first last
  fit="$(printf '%s\n' "${series}" | linreg)"
  first="$(printf '%s\n' "${series}" | head -1 | awk '{print $2}')"
  last="$(printf '%s\n' "${series}" | tail -1 | awk '{print $2}')"
  printf '%s %s %s' "${fit}" "${first}" "${last}"
}

# verdict <slope> <r2> <n>  → LEAK | OK | INSUFFICIENT
verdict() {
  local slope="$1" r2="$2" n="$3"
  (( n < 10 )) && { printf 'INSUFFICIENT'; return; }
  awk -v s="${slope}" -v r="${r2}" -v t="${R2_THRESHOLD}" \
    'BEGIN { print (s > 0 && r > t) ? "LEAK" : "OK" }'
}

declare -A T_SLOPE T_R2 T_N T_FIRST T_LAST T_VERDICT

analyse() { # <key> <csv column>
  local key="$1" col="$2"
  local slope r2 nn first last
  read -r slope _ r2 nn first last <<<"$(trend "${col}")"
  T_SLOPE[$key]="${slope}"; T_R2[$key]="${r2}"; T_N[$key]="${nn}"
  T_FIRST[$key]="${first}"; T_LAST[$key]="${last}"
  T_VERDICT[$key]="$(verdict "${slope}" "${r2}" "${nn}")"
}

per_hour() { awk -v s="$1" 'BEGIN { printf "%.2f", s * 3600 }'; }

report_row() { # <impl> <key> <label> <bytes|plain>
  local impl="$1" key="$2" label="$3" fmt="$4"
  local v="${T_VERDICT[$key]}"
  local first last rate colour state
  if [[ "${fmt}" == "bytes" ]]; then
    first="$(fmt_bytes "${T_FIRST[$key]:-0}")"
    last="$(fmt_bytes "${T_LAST[$key]:-0}")"
    rate="$(awk -v s="${T_SLOPE[$key]}" 'BEGIN { printf "%+.1f MiB", s * 3600 / 1048576 }')"
  else
    first="${T_FIRST[$key]:-—}"
    last="${T_LAST[$key]:-—}"
    rate="$(awk -v s="${T_SLOPE[$key]}" 'BEGIN { printf "%+.2f", s * 3600 }')"
  fi
  case "${v}" in
    LEAK) colour="${C_RED}";    state=FAIL ;;
    OK)   colour="${C_GREEN}";  state=PASS ;;
    *)    colour="${C_YELLOW}"; state=WARN ;;
  esac
  printf '  %s %s %s %s %s %s\n' \
    "$(cell "${label}" 16)" "$(cell "${first}" 14)" "$(cell "${last}" 14)" \
    "$(cell "${rate}" 12)" "$(cell "$(round_num "${T_R2[$key]}" 2)" 7)" \
    "$(cell "${v}" 12 "${colour}")" >&2
  summary_add "${impl} · ${label}" "${state}" \
    "${rate}/h, R²=$(round_num "${T_R2[$key]}" 2), n=${T_N[$key]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# One implementation, start to finish
# ─────────────────────────────────────────────────────────────────────────────
CSV=""; MD=""; K6_LOG=""
RAN=0

run_soak() {
  local impl="$1"
  local base svc container
  base="$(impl_base_url "${impl}")"
  svc="$(impl_service "${impl}")"
  container="$(impl_container "${impl}")"

  section "soak — ${impl}"

  # Preflight — refuse to spend an hour measuring nothing.
  if [[ "$(http_status "${base}/api/v1/health/live" 3)" != "200" ]]; then
    fail "${impl} is not answering at ${base}"
    step "Start it:  docker compose up -d ${svc}   (or make up)"
    step "An hour-long run against a dead port produces an hour of connection errors."
    summary_add "${impl}" SKIP "not running"
    return 0
  fi
  if service_is_501 "${base}"; then
    warn "${impl} returns 501 — the Phase 0 skeleton is still mounted"
    step "A soak of the 501 path measures the error handler. Nothing was run."
    summary_add "${impl}" SKIP "501 skeleton — not implemented yet"
    return 0
  fi
  container_running "${container}" \
    || warn "${container} is not a running container — RSS and FD sampling will be blank"

  CSV="${OUT_DIR}/soak-${impl}.csv"
  MD="${OUT_DIR}/soak-${impl}.md"
  K6_LOG="${OUT_DIR}/soak-${impl}-k6.log"

  info "starting the load generator"
  (
    k6_run tests/load/soak.js \
      -e "BASE_URL=${base}" \
      -e "KNEE_RATE=${KNEE_RATE}" \
      -e "SOAK_FRACTION=${FRACTION}" \
      -e "SOAK_DURATION=${DURATION_S}s" \
      -e "RESULTS_DIR=${OUT_BASE}/${TS}" \
      -e "RUN_LABEL=soak-${impl}" \
      ${SEED_ARG:+-e "SEED_MANIFEST=${SEED_ARG}"} \
      --no-usage-report
  ) >"${K6_LOG}" 2>&1 &
  K6_PID=$!

  # A moment to fail fast (bad URL, unreachable service, bad manifest) rather
  # than discovering it after an hour of empty samples.
  sleep 5
  if ! kill -0 "${K6_PID}" 2>/dev/null; then
    fail "${impl}: the load generator exited immediately"
    tail -30 "${K6_LOG}" | sed 's/^/        /' >&2
    K6_PID=""
    summary_add "${impl}" FAIL "load generator would not start"
    return 1
  fi

  printf 'elapsed_s,iso_time,rss_bytes,open_fds,db_connections,cpu_percent\n' > "${CSV}"

  local start end n=0 now elapsed stats cpu rss fds conns next sleep_for
  start="$(date +%s)"
  end=$(( start + DURATION_S ))

  info "sampling — Ctrl-C stops the run and still writes the report"
  printf '\n  %s %s %s %s %s%s%s\n' \
    "$(cell "elapsed" 9 "${C_DIM}")" "$(cell "rss" 12 "${C_DIM}")" \
    "$(cell "fds" 9 "${C_DIM}")" "$(cell "db conn" 7 "${C_DIM}")" \
    "${C_DIM}" "cpu%" "${C_RESET}" >&2

  while true; do
    now="$(date +%s)"
    (( now >= end )) && break
    kill -0 "${K6_PID}" 2>/dev/null || { warn "load generator stopped early"; break; }

    elapsed=$(( now - start ))
    stats="$(container_stats "${container}" 2>/dev/null || true)"
    cpu="$(awk '{print $1}' <<<"${stats}")"
    rss="$(awk '{print $2}' <<<"${stats}")"
    fds="$(container_open_fds "${container}" 2>/dev/null || true)"
    conns="$(pg_connection_count || true)"

    printf '%d,%s,%s,%s,%s,%s\n' \
      "${elapsed}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${rss:-}" "${fds:-}" "${conns:-}" "${cpu:-}" >> "${CSV}"

    # cell(), not %-Ns: fmt_bytes and the em-dash placeholder are multibyte and
    # printf pads by bytes, which walks the columns leftward as values change.
    printf '  %s %s %s %s %s\n' \
      "$(cell "$(printf '%dm%02ds' $(( elapsed / 60 )) $(( elapsed % 60 )))" 9)" \
      "$(cell "$(fmt_bytes "${rss:-0}")" 12)" \
      "$(cell "${fds:-—}" 9)" "$(cell "${conns:-—}" 7)" "${cpu:-—}" >&2

    n=$(( n + 1 ))
    # Sleep to the next tick rather than for INTERVAL: container_stats alone
    # costs a second or two, and drifting samples make the x-axis a lie.
    next=$(( start + n * INTERVAL ))
    sleep_for=$(( next - $(date +%s) ))
    (( sleep_for > 0 )) && sleep "${sleep_for}"
  done

  step "waiting for the load generator to finish"
  wait "${K6_PID}" 2>/dev/null || warn "k6 exited non-zero — see ${K6_LOG#"${REPO_ROOT}"/}"
  K6_PID=""
  RAN=$(( RAN + 1 ))

  local samples; samples=$(( $(wc -l < "${CSV}") - 1 ))
  info "${samples} samples written to ${CSV#"${REPO_ROOT}"/}"

  analyse rss 3
  analyse fds 4
  analyse conns 5

  section "trend — ${impl}"
  printf '  %s %s %s %s %s %s%s%s\n' \
    "$(cell "metric" 16 "${C_DIM}")" "$(cell "first" 14 "${C_DIM}")" \
    "$(cell "last" 14 "${C_DIM}")" "$(cell "per hour" 12 "${C_DIM}")" \
    "$(cell "R²" 7 "${C_DIM}")" "${C_DIM}" "verdict" "${C_RESET}" >&2

  report_row "${impl}" rss   "RSS"            bytes
  report_row "${impl}" fds   "open FDs"       plain
  report_row "${impl}" conns "DB connections" plain

  {
    echo "# Soak — ${impl}"
    echo
    echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- duration: ${DURATION} (${DURATION_S}s), ${samples} samples every ${INTERVAL}s"
    echo "- load: ${RATE} rps (${FRACTION} x knee ${KNEE_RATE}), open-loop constant-arrival-rate"
    echo "- container: ${container}"
    echo
    echo "## Verdict"
    echo
    echo "| metric | first | last | change/hour | R² | n | verdict |"
    echo "|---|---|---|---|---|---|---|"
    printf '| RSS | %s | %s | %s MiB | %s | %s | %s |\n' \
      "$(fmt_bytes "${T_FIRST[rss]:-0}")" "$(fmt_bytes "${T_LAST[rss]:-0}")" \
      "$(awk -v s="${T_SLOPE[rss]}" 'BEGIN { printf "%+.1f", s * 3600 / 1048576 }')" \
      "$(round_num "${T_R2[rss]}" 3)" "${T_N[rss]}" "${T_VERDICT[rss]}"
    printf '| open FDs | %s | %s | %s | %s | %s | %s |\n' \
      "${T_FIRST[fds]:-—}" "${T_LAST[fds]:-—}" "$(per_hour "${T_SLOPE[fds]}")" \
      "$(round_num "${T_R2[fds]}" 3)" "${T_N[fds]}" "${T_VERDICT[fds]}"
    printf '| DB connections | %s | %s | %s | %s | %s | %s |\n' \
      "${T_FIRST[conns]:-—}" "${T_LAST[conns]:-—}" "$(per_hour "${T_SLOPE[conns]}")" \
      "$(round_num "${T_R2[conns]}" 3)" "${T_N[conns]}" "${T_VERDICT[conns]}"
    echo
    echo "LEAK = positive slope with R² > ${R2_THRESHOLD}. A metric that ends higher than"
    echo "it started but fits the line badly is noise or a sawtooth, not a leak."
    echo
    echo "## Data"
    echo
    echo "\`soak-${impl}.csv\` — plot column 3 (RSS) against column 1 (elapsed seconds)."
    echo "The graph is what convinces people; the regression only tells you to draw it."
    echo
    echo "## k6"
    echo
    echo '```'
    tail -30 "${K6_LOG}" 2>/dev/null || echo "(no k6 output)"
    echo '```'
  } > "${MD}"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
summary_reset
RC=0
for impl in "${IMPLS[@]}"; do
  run_soak "${impl}" || RC=1
done
trap - INT TERM

summary_print "soak"

LEAKS="$(summary_count FAIL)"
printf '  %sresults  %s%s\n\n' "${C_DIM}" "${OUT_BASE}/${TS}" "${C_RESET}" >&2

if (( RAN == 0 )); then
  warn "nothing was soaked — no selected implementation was running"
  step "Start the stack:  make up"
  exit 1
fi
if (( LEAKS > 0 )); then
  fail "${LEAKS} metric(s) rose monotonically — this looks like a leak"
  step "Plot the CSV before you believe the regression, and before you disbelieve it."
  step "Then profile the growth:  scripts/profile.sh --impl ${IMPLS[0]}"
  exit 1
fi
ok "nothing trends upward across ${RAN} run(s) — no leak visible over ${DURATION}"
exit "${RC}"
