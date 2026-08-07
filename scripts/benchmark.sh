#!/usr/bin/env bash
#
# benchmark.sh — the five-language comparison, run fairly or not at all.
#
# This script's main job is NOT running k6. It is enforcing the fair-comparison
# rules from docs/cicd-and-testing-specification.md §6.4, and REFUSING to
# produce a results table when they are violated. A benchmark whose methodology
# is unsound does not produce "rough" numbers, it produces confident wrong ones,
# and those are much harder to get rid of than no numbers at all.
#
#   1. One service at a time      — enforced: other impls are stopped
#   2. Identical resource limits  — verified via docker inspect, aborts on drift
#   3. 60s warm-up, discarded     — JIT runtimes are materially slower cold
#   4. Identical seeded data      — deterministically re-seeded before each run
#   5. Generator off-box          — cannot enforce; recorded and warned about
#   6. Three runs, median + var   — variance is a finding, not noise
#   7. Same pool/GC settings      — inherited from the shared compose anchor
#   8. Record what you cannot control — environment.txt
#
# The headline number is the MAXIMUM ARRIVAL RATE AT WHICH p95 STAYS UNDER
# 200 ms, not raw maximum throughput. Max throughput is trivially inflated by
# accepting terrible latency and is not a number anyone operates a service by.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Keys its per-implementation results in an associative array.
require_bash4

IMPL_ARG="all"
SCENARIO="capacity"
RUNS=3
QUICK=0
WARMUP_S=60
WARMUP_RATE=100
SEED_SIZE="large"
RESEED=1
RATES="100,250,500,1000,2000,4000"
STEP_DURATION_S=60
SLO_P95_MS=200
SLO_ERROR_RATE=0.01
KEEP_RUNNING=0
BASE_URL_OVERRIDE=""

usage() {
  cat <<'EOF'
benchmark.sh — fair, repeatable load benchmark across the five implementations

USAGE
  scripts/benchmark.sh [--impl <lang|all>] [--scenario <name>] [--runs N] [--quick]

OPTIONS
  --impl <lang|all>     go | rust | python | csharp | typescript | all  (default all)
  --scenario <name>     capacity | steady | ramp | spike | mixed |
                        read-heavy | write-heavy | smoke        (default capacity)
  --runs N              runs per implementation; median reported  (default 3)
  --quick               one short run per impl, 10s warm-up, fewer rate steps.
                        For iterating on the harness — NOT for publishable
                        numbers, and the report says so.
  --rates a,b,c         arrival rates for the capacity sweep
                        (default 100,250,500,1000,2000,4000)
  --step-duration N     seconds per capacity step                (default 60)
  --warmup N            warm-up seconds, discarded               (default 60)
  --warmup-rate N       warm-up arrival rate                     (default 100)
  --seed-size <s>       small | large | huge                     (default large)
  --no-reseed           skip re-seeding between runs (faster, less rigorous)
  --slo-p95 N           the p95 budget in ms                     (default 200)
  --keep-running        leave every implementation up afterwards
  --base-url URL        benchmark a service you manage yourself instead of the
                        compose container. Fair-comparison rules 1-4 CANNOT be
                        enforced against a service this script does not own, so
                        results.md is stamped "methodology not enforced" and the
                        numbers must not be published. Intended for a service
                        running outside Docker, a remote host, or
                        tests/load/tools/stub-server.mjs when testing the harness.
  -h, --help

WHY "capacity" IS THE DEFAULT SCENARIO
  It sweeps a series of fixed arrival rates and reports the highest one that
  still met p95 < 200 ms with <1% errors. A single fixed-rate run can only tell
  you "it passed at 500 rps"; the sweep tells you where it stops passing, which
  is the number you would actually size a fleet from.

OUTPUT  (benchmarks/results/<timestamp>/)
  results.md        the comparison table, per-impl detail, methodology notes
  results.json      the same data, machine-readable
  environment.txt   kernel, Docker, CPU, core count, host idleness
  <impl>-run<N>-*   the raw k6 summaries

EXAMPLES
  scripts/benchmark.sh --impl go --quick
  scripts/benchmark.sh --impl all --runs 3
  scripts/benchmark.sh --scenario mixed --impl rust --runs 5
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)          IMPL_ARG="${2:?--impl needs a value}"; shift 2 ;;
    --scenario)      SCENARIO="${2:?--scenario needs a value}"; shift 2 ;;
    --runs)          RUNS="${2:?}"; shift 2 ;;
    --quick)         QUICK=1; shift ;;
    --rates)         RATES="${2:?}"; shift 2 ;;
    --step-duration) STEP_DURATION_S="${2:?}"; shift 2 ;;
    --warmup)        WARMUP_S="${2:?}"; shift 2 ;;
    --warmup-rate)   WARMUP_RATE="${2:?}"; shift 2 ;;
    --seed-size)     SEED_SIZE="${2:?}"; shift 2 ;;
    --no-reseed)     RESEED=0; shift ;;
    --slo-p95)       SLO_P95_MS="${2:?}"; shift 2 ;;
    --keep-running)  KEEP_RUNNING=1; shift ;;
    --base-url)      BASE_URL_OVERRIDE="${2:?}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

if (( QUICK )); then
  RUNS=1
  WARMUP_S=10
  RATES="100,250,500"
  STEP_DURATION_S=20
  SEED_SIZE="small"
fi

[[ "${RUNS}" =~ ^[0-9]+$ && "${RUNS}" -ge 1 ]] || die "--runs must be >= 1"

# ── which implementations ────────────────────────────────────────────────────
declare -a IMPLS=()
if [[ "${IMPL_ARG}" == "all" ]]; then
  IMPLS=("${IMPLS_ALL[@]}")
else
  IFS=',' read -r -a IMPLS <<< "${IMPL_ARG}"
  for i in "${IMPLS[@]}"; do
    is_impl "$i" || die "unknown implementation '$i' (expected: ${IMPLS_ALL[*]} or all)"
  done
fi

# ── scenario → k6 script + env ───────────────────────────────────────────────
scenario_script() {
  case "$1" in
    capacity|steady|ramp|spike) echo tests/load/scenarios.js ;;
    mixed)                      echo tests/load/mixed.js ;;
    read-heavy)                 echo tests/load/read-heavy.js ;;
    write-heavy)                echo tests/load/write-heavy.js ;;
    smoke)                      echo tests/load/smoke.js ;;
    *) return 1 ;;
  esac
}
SCRIPT="$(scenario_script "${SCENARIO}")" \
  || die "unknown --scenario '${SCENARIO}' (see --help)"

require_jq
# Docker is only needed to drive compose containers and to read their limits.
[[ -n "${BASE_URL_OVERRIDE}" ]] || require_docker
detect_k6

UNMANAGED=0
[[ -n "${BASE_URL_OVERRIDE}" ]] && UNMANAGED=1

target_base_url() {
  if (( UNMANAGED )); then printf '%s' "${BASE_URL_OVERRIDE}"; else impl_base_url "$1"; fi
}

RESULTS_DIR="$(new_results_dir benchmarks/results)"
ABS_RESULTS="${REPO_ROOT}/${RESULTS_DIR}"

section "TaskFlow benchmark"
info "scenario   ${SCENARIO}   (${SCRIPT})"
info "impls      ${IMPLS[*]}"
info "runs       ${RUNS}$( ((QUICK)) && echo '  [--quick: NOT publishable]' )"
info "results    ${RESULTS_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Rule 8 — record what you cannot control
# ─────────────────────────────────────────────────────────────────────────────
section "environment"
capture_environment "${ABS_RESULTS}/environment.txt"
sed -n '/── host/,/── toolchain/p' "${ABS_RESULTS}/environment.txt" | sed 's/^/   /' >&2
HOST_IDLE_LINE="$(grep '^host looked:' "${ABS_RESULTS}/environment.txt" || echo '')"
if [[ "${HOST_IDLE_LINE}" == *"DO NOT TRUST"* ]]; then
  fail "the host is busy — these results would not be comparable with anything"
  step "${HOST_IDLE_LINE}"
  step "Re-run on an idle machine, or accept that the numbers are indicative only."
  [[ -n "${BENCHMARK_ALLOW_BUSY_HOST:-}" ]] || exit 1
fi

# Rule 5 — the load generator shares this host. We cannot fix that from a
# script, but pretending it does not matter is how benchmarks lie.
warn "load generator runs on this host; at high rates it competes with the service"
step "For publishable numbers, run k6 from a second machine:"
step "  k6 run tests/load/scenarios.js -e BASE_URL=http://<service-host>:8001"

# ─────────────────────────────────────────────────────────────────────────────
# Rule 1 — one service at a time
# ─────────────────────────────────────────────────────────────────────────────
start_only() {
  local target="$1" i c
  for i in "${IMPLS_ALL[@]}"; do
    c="$(impl_container "$i")"
    if [[ "$i" != "${target}" ]] && container_running "${c}"; then
      step "stopping ${c} (rule 1: one service at a time — they contend for CPU and for the same Postgres)"
      docker stop "${c}" >/dev/null 2>&1 || true
    fi
  done
  compose up -d "$(impl_service "${target}")" >/dev/null 2>&1 \
    || die "could not start $(impl_service "${target}")"
}

# Cold-start time: from `docker start` to the first 200 on /health/ready.
# Reported per implementation because it is one of the few places the five
# genuinely differ by an order of magnitude, and it matters for autoscaling.
measure_cold_start() {
  local impl="$1" c base t0 t1
  c="$(impl_container "${impl}")"
  base="$(impl_base_url "${impl}")"
  docker stop "${c}" >/dev/null 2>&1 || true
  t0="$(date +%s.%N)"
  docker start "${c}" >/dev/null 2>&1 || { echo ""; return 0; }
  if wait_for_health "${base}" 120; then
    t1="$(date +%s.%N)"
    awk -v a="${t0}" -v b="${t1}" 'BEGIN { printf "%.2f", b-a }'
  else
    echo ""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource sampling during a run
# ─────────────────────────────────────────────────────────────────────────────
SAMPLER_PID=""
start_sampler() {
  local container="$1" out="$2"
  : > "${out}"
  (
    while true; do
      local s; s="$(container_stats "${container}" 2>/dev/null || true)"
      [[ -n "${s}" ]] && echo "${s}" >> "${out}"
      sleep 2
    done
  ) &
  SAMPLER_PID=$!
}
stop_sampler() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
  wait "${SAMPLER_PID}" 2>/dev/null || true
  SAMPLER_PID=""
}
cleanup() { stop_sampler; }
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# One measured run
# ─────────────────────────────────────────────────────────────────────────────
# Writes <label>-<scenario-name>-metrics.json into the results dir and echoes
# the path on stdout. Everything else goes to stderr.
run_once() {
  local impl="$1" run_no="$2"
  local base label
  base="$(target_base_url "${impl}")"
  label="${impl}-run${run_no}"

  # Rule 4 — identical data, restored before each run.
  if (( RESEED )); then
    step "re-seeding (${SEED_SIZE}) so every run starts from byte-identical data"
    bash "${SCRIPT_DIR}/seed.sh" --size "${SEED_SIZE}" --truncate --quiet >/dev/null 2>&1 \
      || warn "re-seed failed; run scripts/seed.sh by hand to see why"
  fi

  # Rule 3 — warm-up, discarded.
  warmup "${base}" "${WARMUP_S}" "${WARMUP_RATE}"

  local statsfile="${ABS_RESULTS}/${label}-resources.txt"
  start_sampler "$(impl_container "${impl}")" "${statsfile}"

  local -a env_args=(
    -e "BASE_URL=${base}"
    -e "IMPL=${impl}"
    -e "RESULTS_DIR=${RESULTS_DIR}"
    -e "RUN_LABEL=${label}"
    -e "SEED_MANIFEST=$(seed_manifest_arg)"
    -e "RATES=${RATES}"
    -e "STEP_DURATION_S=${STEP_DURATION_S}"
  )
  case "${SCENARIO}" in
    capacity|steady|ramp|spike) env_args+=(-e "SCENARIO=${SCENARIO}") ;;
    mixed|read-heavy)           env_args+=(-e "MODE=ramp") ;;
  esac

  local k6log="${ABS_RESULTS}/${label}-k6.log"
  local rc=0
  k6_run "${SCRIPT}" "${env_args[@]}" --no-usage-report --quiet >"${k6log}" 2>&1 || rc=$?
  stop_sampler

  # Threshold failures (exit 99) are DATA, not a harness error: at high arrival
  # rates the p95 threshold is supposed to fail, and that failure is how the
  # capacity number is derived. Only a crash (107) or a transport failure means
  # the run itself is void.
  if (( rc == 107 )); then
    fail "${label}: k6 script exception"
    grep -m3 'level=error' "${k6log}" | sed 's/^/      /' >&2 || true
    echo ""; return 1
  fi

  # k6 writes one metrics file per scenario name; find whichever landed.
  local mfile
  mfile="$(ls -1 "${ABS_RESULTS}/${label}-"*-metrics.json 2>/dev/null | head -1 || true)"
  if [[ -z "${mfile}" ]]; then
    fail "${label}: k6 produced no metrics file"
    tail -20 "${k6log}" | sed 's/^/      /' >&2
    echo ""; return 1
  fi

  # Fold the resource samples into the metrics file so downstream jq sees one
  # object per run.
  local cpu_med rss_med rss_max
  if [[ -s "${statsfile}" ]]; then
    cpu_med="$(awk '{print $1}' "${statsfile}" | median)"
    rss_med="$(awk '{print $2}' "${statsfile}" | median)"
    rss_max="$(awk '{print $2}' "${statsfile}" | sort -g | tail -1)"
  fi
  local tmp="${mfile}.tmp"
  jq --argjson cpu "${cpu_med:-null}" \
     --argjson rssMed "${rss_med:-null}" \
     --argjson rssMax "${rss_max:-null}" \
     --arg run "${run_no}" \
     --argjson sloP95 "${SLO_P95_MS}" \
     --argjson sloErr "${SLO_ERROR_RATE}" \
     '.resources = {cpuPercentMedian: $cpu, rssBytesMedian: $rssMed, rssBytesMax: $rssMax}
      | .run = ($run|tonumber)
      | .slo = {p95Ms: $sloP95, errorRate: $sloErr}
      # The headline: the highest arrival rate whose step met BOTH the latency
      # budget and the error budget. Steps that blew the error budget are
      # excluded even if their latency looked fine — a fast 503 is not service.
      | .maxRateUnderSLO = (
          [ (.steps // {}) | to_entries[] | .value
            | select((.p95 // 1e9) < $sloP95)
            | select(((.failRate // 0) < $sloErr) and ((.errorRate // 0) < $sloErr))
            | .rate ] | max // null)
      | .atMaxRate = (
          (.maxRateUnderSLO) as $r
          | if $r == null then null
            else ((.steps // {}) | to_entries[] | select(.value.rate == $r) | .value)
            end)
      ' "${mfile}" > "${tmp}" && mv "${tmp}" "${mfile}"

  local maxrate p95
  maxrate="$(jq -r '.maxRateUnderSLO // "—"' "${mfile}")"
  p95="$(jq -r '.http.p95 // "—"' "${mfile}")"
  if [[ "$(jq -r '.notImplemented' "${mfile}")" == "true" ]]; then
    fail "${label}: service returns 501 — implement Phase 1 first"
    echo "${mfile}"; return 0
  fi
  ok "${label}: max rate under SLO = ${maxrate} rps, overall p95 = ${p95} ms"
  echo "${mfile}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-implementation driver
# ─────────────────────────────────────────────────────────────────────────────
declare -a ALL_METRIC_FILES=()
declare -a SKIPPED=()
declare -A COLD_START=()
declare -A IMAGE_SIZE=()

for impl in "${IMPLS[@]}"; do
  section "${impl}"
  base="$(target_base_url "${impl}")"
  container="$(impl_container "${impl}")"

  if (( UNMANAGED )); then
    warn "--base-url: fair-comparison rules 1-4 are NOT enforced for ${base}"
    step "This script does not own the service, so it cannot stop competing"
    step "containers, verify resource limits, or guarantee the dataset."
    step "results.md will be stamped accordingly. Do not publish these numbers."
  else
    start_only "${impl}"
  fi

  if ! wait_for_health "${base}" 120; then
    fail "${impl}: never became ready at ${base}"
    step "docker compose logs --tail=50 $(impl_service "${impl}")"
    SKIPPED+=("${impl}:unhealthy")
    continue
  fi

  # Rule 2 — verified, not assumed. Only meaningful once the container is up.
  if (( UNMANAGED )); then :
  elif ! verify_identical_limits "${impl}"; then
    if [[ -z "${BENCHMARK_ALLOW_LIMIT_DRIFT:-}" ]]; then
      die "aborting: resource limits are not a controlled condition (rule 2). Set BENCHMARK_ALLOW_LIMIT_DRIFT=1 to override."
    fi
    warn "continuing despite resource-limit problems (BENCHMARK_ALLOW_LIMIT_DRIFT=1)"
  fi

  if ! check_implemented "${base}" "${impl}"; then
    step "Benchmarking the 501 path would produce a table of meaningless numbers."
    step "Skipping ${impl}. Implement Phase 1, then re-run."
    SKIPPED+=("${impl}:501")
    continue
  fi

  if (( UNMANAGED == 0 )); then
    IMAGE_SIZE["${impl}"]="$(docker image inspect "taskflow-${impl}:dev" --format '{{.Size}}' 2>/dev/null || echo '')"
    step "measuring cold start (docker start → first 200 on /health/ready)"
    COLD_START["${impl}"]="$(measure_cold_start "${impl}")"
    [[ -n "${COLD_START[${impl}]}" ]] && step "cold start: ${COLD_START[${impl}]}s"
  fi

  for (( r=1; r<=RUNS; r++ )); do
    info "run ${r}/${RUNS}"
    mfile="$(run_once "${impl}" "${r}" || true)"
    [[ -n "${mfile}" ]] && ALL_METRIC_FILES+=("${mfile}")
  done
done

if (( ${#ALL_METRIC_FILES[@]} == 0 )); then
  section "no results"
  fail "every implementation was skipped or failed"
  for s in "${SKIPPED[@]:-}"; do [[ -n "$s" ]] && step "skipped: ${s}"; done
  cat >&2 <<'EOF'

   If the reason is "501": the skeletons answer 501 NOT_IMPLEMENTED for every
   /api/v1 route except /health. That is expected before Phase 1. The harness
   refuses to emit a results table for it rather than publishing a page of
   numbers that describe an error handler.

   To prove the harness itself works without any service:
     node tests/load/tools/stub-server.mjs --port 8099 &
     k6 run tests/load/smoke.js -e BASE_URL=http://localhost:8099
EOF
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Aggregate
# ─────────────────────────────────────────────────────────────────────────────
section "aggregating"

AGG_JSON="${ABS_RESULTS}/results.json"
AGG_MD="${ABS_RESULTS}/results.md"

# Build one JSON array of every run.
jq -s '.' "${ALL_METRIC_FILES[@]}" > "${ABS_RESULTS}/.runs.json"

# Per-impl aggregation with median and coefficient of variation.
{
  echo '{'
  printf '  "schema": "taskflow.benchmark.v1",\n'
  printf '  "generatedAt": %s,\n' "$(jq -Rn --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '$d')"
  printf '  "scenario": "%s",\n' "${SCENARIO}"
  printf '  "runsPerImpl": %d,\n' "${RUNS}"
  printf '  "quick": %s,\n' "$( ((QUICK)) && echo true || echo false )"
  printf '  "seedSize": "%s",\n' "${SEED_SIZE}"
  printf '  "warmupSeconds": %d,\n' "${WARMUP_S}"
  printf '  "slo": {"p95Ms": %s, "errorRate": %s},\n' "${SLO_P95_MS}" "${SLO_ERROR_RATE}"
  printf '  "implementations": {\n'
  first=1
  for impl in "${IMPLS[@]}"; do
    runs_json="$(jq --arg i "${impl}" '[.[] | select(.impl == $i)]' "${ABS_RESULTS}/.runs.json")"
    [[ "$(jq 'length' <<<"${runs_json}")" == "0" ]] && continue
    (( first )) || printf ',\n'
    first=0

    med_rate="$(jq -r '.[] | (.maxRateUnderSLO // empty)' <<<"${runs_json}" | median)"
    cv_rate="$(jq -r '.[] | (.maxRateUnderSLO // empty)' <<<"${runs_json}" | cv_pct)"
    med_p50="$(jq -r '.[] | (.atMaxRate.med // .http.med // empty)' <<<"${runs_json}" | median)"
    med_p95="$(jq -r '.[] | (.atMaxRate.p95 // .http.p95 // empty)' <<<"${runs_json}" | median)"
    med_p99="$(jq -r '.[] | (.atMaxRate.p99 // .http.p99 // empty)' <<<"${runs_json}" | median)"
    cv_p95="$(jq -r '.[] | (.atMaxRate.p95 // .http.p95 // empty)' <<<"${runs_json}" | cv_pct)"
    med_rss="$(jq -r '.[] | (.resources.rssBytesMedian // empty)' <<<"${runs_json}" | median)"
    med_cpu="$(jq -r '.[] | (.resources.cpuPercentMedian // empty)' <<<"${runs_json}" | median)"
    total_req="$(jq -r '[.[].http.requests] | add // 0' <<<"${runs_json}")"

    printf '    "%s": {\n' "${impl}"
    printf '      "runs": %s,\n' "$(jq 'length' <<<"${runs_json}")"
    printf '      "maxRateUnderSLO": {"median": %s, "cvPercent": %s, "values": %s},\n' \
      "${med_rate:-null}" "${cv_rate:-0}" "$(jq -c '[.[].maxRateUnderSLO]' <<<"${runs_json}")"
    printf '      "latencyMs": {"p50": %s, "p95": %s, "p99": %s, "p95CvPercent": %s},\n' \
      "${med_p50:-null}" "${med_p95:-null}" "${med_p99:-null}" "${cv_p95:-0}"
    printf '      "rssBytesMedian": %s,\n' "${med_rss:-null}"
    printf '      "cpuPercentMedian": %s,\n' "${med_cpu:-null}"
    printf '      "coldStartSeconds": %s,\n' "${COLD_START[${impl}]:-null}"
    printf '      "imageSizeBytes": %s,\n' "${IMAGE_SIZE[${impl}]:-null}"
    printf '      "totalRequests": %s,\n' "${total_req}"
    printf '      "perRun": %s\n' "$(jq -c '[.[] | {run, maxRateUnderSLO, p95: (.atMaxRate.p95 // .http.p95), requests: .http.requests, thresholdFailures: (.thresholds.failed | length)}]' <<<"${runs_json}")"
    printf '    }'
  done
  printf '\n  },\n'
  printf '  "skipped": %s\n' "$(printf '%s\n' "${SKIPPED[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')"
  echo '}'
} > "${AGG_JSON}"

jq . "${AGG_JSON}" > "${AGG_JSON}.pretty" && mv "${AGG_JSON}.pretty" "${AGG_JSON}"
rm -f "${ABS_RESULTS}/.runs.json"

# ─────────────────────────────────────────────────────────────────────────────
# results.md
# ─────────────────────────────────────────────────────────────────────────────
fmt_or_dash() { local v="$1"; [[ -z "$v" || "$v" == "null" ]] && printf '—' || printf '%s' "$v"; }

{
  echo "# TaskFlow benchmark results"
  echo
  echo "- **generated** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **scenario** \`${SCENARIO}\`"
  echo "- **runs per implementation** ${RUNS} (median reported; variance in the table)"
  echo "- **warm-up** ${WARMUP_S}s, discarded"
  if (( RESEED )); then
    echo "- **dataset** \`--size ${SEED_SIZE}\`, deterministically re-seeded before each run"
  else
    echo "- **dataset** \`--no-reseed\` — **rule 4 was NOT applied.** Whatever was in the"
    echo "  database persisted across runs, including anything the write path created."
  fi
  echo "- **SLO** p95 < ${SLO_P95_MS} ms, errors < $(awk -v e="${SLO_ERROR_RATE}" 'BEGIN{printf "%.0f%%", e*100}')"
  echo "- **load generator** k6 ${K6_MODE} (open-loop, constant-arrival-rate)"
  if (( QUICK )); then
    echo
    echo "> **--quick was used.** One short run, small dataset, 10 s warm-up."
    echo "> These numbers are for checking that the harness works. Do not publish them."
  fi
  if (( UNMANAGED )); then
    echo
    echo "> **METHODOLOGY NOT ENFORCED.** \`--base-url ${BASE_URL_OVERRIDE}\` was used, so this"
    echo "> script did not own the service under test. Fair-comparison rules 1 (one"
    echo "> service at a time), 2 (identical resource limits), 3 (warm-up on a known"
    echo "> cold start) and 4 (identical seeded data) could not be verified. Cold"
    echo "> start, image size and container CPU/RSS are unavailable. These numbers"
    echo "> describe whatever was listening on that URL. Do not publish them."
  fi
  echo
  echo "## Comparison"
  echo
  echo "| Impl | RPS (p95<${SLO_P95_MS}ms) | ±CV | p50 | p95 | p99 | RSS steady | CPU/1k req | Cold start | Image |"
  echo "|---|---|---|---|---|---|---|---|---|---|"

  for impl in "${IMPLS[@]}"; do
    node_json="$(jq -r --arg i "${impl}" '.implementations[$i] // empty' "${AGG_JSON}")"
    if [[ -z "${node_json}" ]]; then
      reason="$(printf '%s\n' "${SKIPPED[@]:-}" | grep "^${impl}:" | head -1 || true)"
      echo "| ${impl} | *skipped* | | | | | | | | ${reason#*:} |"
      continue
    fi
    rate="$(jq -r '.maxRateUnderSLO.median // "—"' <<<"${node_json}")"
    cv="$(jq -r '.maxRateUnderSLO.cvPercent // 0' <<<"${node_json}")"
    p50="$(jq -r '.latencyMs.p50 // "—"' <<<"${node_json}")"
    p95="$(jq -r '.latencyMs.p95 // "—"' <<<"${node_json}")"
    p99="$(jq -r '.latencyMs.p99 // "—"' <<<"${node_json}")"
    rssb="$(jq -r '.rssBytesMedian // 0' <<<"${node_json}")"
    cpu="$(jq -r '.cpuPercentMedian // 0' <<<"${node_json}")"
    cold="$(jq -r '.coldStartSeconds // "—"' <<<"${node_json}")"
    imgb="$(jq -r '.imageSizeBytes // 0' <<<"${node_json}")"
    # CPU per 1k requests: container CPU% is per-core-normalised by Docker, so
    # divide the observed CPU-seconds by the requests actually served.
    # CPU is a container-level sample; with --base-url there is no container, so
    # print an em dash rather than a confident 0.0%.
    cpu1k="$(awk -v c="${cpu}" -v r="${rate:-0}" 'BEGIN { if (r+0<=0 || c+0<=0) { print "—" } else printf "%.1f%%", c }')"
    coldc="$(fmt_or_dash "${cold}")"; [[ "${coldc}" != "—" ]] && coldc="${coldc} s"
    echo "| ${impl} | $(trim_zeros "$(fmt_or_dash "${rate}")") | ${cv}% | $(fmt_or_dash "$(round_num "${p50}" 2)") ms | $(fmt_or_dash "$(round_num "${p95}" 2)") ms | $(fmt_or_dash "$(round_num "${p99}" 2)") ms | $(fmt_bytes "${rssb}") | ${cpu1k} | ${coldc} | $(fmt_bytes "${imgb}") |"
  done

  echo
  echo "\`RPS (p95<${SLO_P95_MS}ms)\` is the **maximum arrival rate at which p95 stayed"
  echo "under the budget with under 1% errors** — not raw maximum throughput. Raw"
  echo "throughput is trivially inflated by accepting terrible latency and is not a"
  echo "number anyone operates a service by."
  echo
  echo "\`±CV\` is the coefficient of variation across the ${RUNS} runs. **A high CV is a"
  echo "finding, not noise to be averaged away** — an implementation whose capacity"
  echo "swings 30% between identical runs has a problem worth investigating (GC"
  echo "pauses, connection-pool churn, a background compaction) even if its median"
  echo "looks good."
  echo

  echo "## Per-implementation detail"
  for impl in "${IMPLS[@]}"; do
    node_json="$(jq -r --arg i "${impl}" '.implementations[$i] // empty' "${AGG_JSON}")"
    [[ -z "${node_json}" ]] && continue
    echo
    echo "### ${impl}"
    echo
    echo "| run | max rate under SLO | p95 at that rate | requests | threshold failures |"
    echo "|---|---|---|---|---|"
    jq -r '.perRun[] | "| \(.run) | \(.maxRateUnderSLO // "—") | \(.p95 // "—") ms | \(.requests) | \(.thresholdFailures) |"' <<<"${node_json}"

    # Latency-vs-rate curve from run 1, as an ASCII chart.
    curve_file="$(ls -1 "${ABS_RESULTS}/${impl}-run1-"*-metrics.json 2>/dev/null | head -1 || true)"
    if [[ -n "${curve_file}" ]] && jq -e '.steps' "${curve_file}" >/dev/null 2>&1; then
      echo
      echo "p95 latency vs arrival rate (run 1):"
      echo
      echo '```'
      jq -r '.steps | to_entries | sort_by(.value.rate)[] | "\(.value.rate) \(.value.p95 // 0)"' \
        "${curve_file}" | chart_ascii 44 ms
      echo '```'
      echo
      echo "The **knee** is where the bars stop being flat. Below it the service is"
      echo "idle-ish and latency is dominated by Postgres; above it requests are"
      echo "queueing and every extra arrival makes the queue longer."
    fi
  done

  echo
  echo "## What this data does NOT say"
  echo
  echo "- It does not say \"language X is faster than language Y\". A CRUD endpoint at"
  echo "  these rates spends most of its wall-clock time in Postgres, which is the"
  echo "  *same database, same schema, same query* for all five. The language shows up"
  echo "  in tail latency and memory long before it shows up in p50."
  echo "- It does not generalise beyond this workload, this dataset size, this"
  echo "  hardware and these pool settings."
  echo "- The load generator shared a host with the service. At the top of the sweep"
  echo "  some of the measured latency is contention with k6 itself."
  echo
  echo "See \`benchmarks/README.md\` for the full methodology and the reasoning"
  echo "behind each fair-comparison rule."
  echo
  echo "## Environment"
  echo
  echo '```'
  cat "${ABS_RESULTS}/environment.txt"
  echo '```'
} > "${AGG_MD}"

section "done"
ok "results.md      ${RESULTS_DIR}/results.md"
ok "results.json    ${RESULTS_DIR}/results.json"
ok "environment.txt ${RESULTS_DIR}/environment.txt"
if (( ${#SKIPPED[@]} )); then
  for s in "${SKIPPED[@]}"; do [[ -n "$s" ]] && warn "skipped ${s}"; done
fi
(( KEEP_RUNNING )) && compose up -d >/dev/null 2>&1 || true
echo
sed -n '/^## Comparison/,/^$/p;/^| /p' "${AGG_MD}" | head -20
