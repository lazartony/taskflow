#!/usr/bin/env bash
#
# bench-cache.sh — what does Redis/Valkey actually buy you?
#
# Runs the SAME service, against the SAME data, with the SAME request stream,
# twice: once with CACHE_ENABLED=false and once with CACHE_ENABLED=true. One
# variable changes. Everything else is held still, on purpose, because "we added
# a cache and things got faster" is an anecdote until you can show that nothing
# else moved.
#
# Method (per implementation):
#   1. Seed a deterministic dataset (N users x M tasks) — identical both runs
#   2. Restart the service with CACHE_ENABLED=false
#   3. Warm up 60s (discarded), then run the read-heavy profile
#   4. Capture p50/p95/p99, throughput under the p95 SLO, DB queries/sec
#      (pg_stat_statements delta), CPU, RSS
#   5. Restart with CACHE_ENABLED=true
#   6. Warm up 60s, run the IDENTICAL profile
#   7. Capture the same metrics, plus the cache hit ratio
#   8. Emit a comparison table, a divergence chart and a markdown report
#
# Three measurements, in increasing order of persuasiveness:
#
#   latency        p95 dropped 40%.  Invites argument about noise.
#   throughput     capacity tripled. Better, but depends on the load shape.
#   DB QUERIES     the database served 87% fewer queries. This is the one.
#                  It is a count, not a statistic; it is measured on the
#                  database rather than on the client; and it maps directly to
#                  "we can defer buying a bigger Postgres".
#
# Plus two things a single-point comparison cannot show:
#
#   the RAMP       caching often buys almost nothing at low load and an enormous
#                  amount past the knee. WHERE the two curves diverge is the
#                  real lesson; a single arrival rate hides it entirely.
#   the STAMPEDE   N concurrent requests at one cold key. Without a stampede
#                  lock, N of them reach the origin. With one, ~1 does. That is
#                  a different mechanism from "the cache is warm" and it needs
#                  its own demonstration.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Keys its per-implementation results in an associative array.
require_bash4

IMPL_ARG="go"
RATE=500
DURATION="2m"
WARMUP_S=60
WARMUP_RATE=100
SEED_SIZE="large"
RESEED=1
DO_RAMP=1
DO_STAMPEDE=1
RATES="100,250,500,1000,2000,4000"
STEP_DURATION_S=45
STAMPEDE_N=500
SLO_P95_MS=200
HOT_PAGES=8
NO_RESTART=0
BASE_URL_OVERRIDE=""

usage() {
  cat <<'EOF'
bench-cache.sh — measure what caching buys, with evidence

USAGE
  scripts/bench-cache.sh [--impl <lang>] [options]

OPTIONS
  --impl <lang|all>     go | rust | python | csharp | typescript | all  (default go)
  --rate N              arrival rate for the single-point run       (default 500)
  --duration D          duration of the single-point run            (default 2m)
  --rates a,b,c         arrival rates for the divergence sweep
                        (default 100,250,500,1000,2000,4000)
  --step-duration N     seconds per sweep step                      (default 45)
  --stampede-n N        concurrent requests at one cold key         (default 500)
  --hot-pages N         distinct list pages the workload touches    (default 8)
  --warmup N            warm-up seconds, discarded                  (default 60)
  --warmup-rate N       arrival rate during warm-up                 (default 100)
  --seed-size <s>       small | large | huge                        (default large)
  --no-reseed           do not re-seed before the runs
  --no-ramp             skip the divergence sweep
  --no-stampede         skip the stampede demonstration
  --no-restart          do not restart the service between configurations.
                        Only useful if you flip CACHE_ENABLED some other way;
                        the report will say the isolation was weaker.
  --slo-p95 N           p95 budget in ms                            (default 200)
  --base-url URL        target a service you manage yourself instead of the
                        compose container. Implies --no-restart: this script
                        will not stop, start or reconfigure anything, so YOU
                        must flip CACHE_ENABLED between the two halves. Useful
                        for a service running outside Docker, a remote host, or
                        tests/load/tools/stub-server.mjs when you are testing
                        the harness itself.
  -h, --help

ENVIRONMENT
  CACHE_TOGGLE_HOOK   with --base-url / --no-restart, a command invoked as
                      "$CACHE_TOGGLE_HOOK true|false" before each half. It must
                      return only once the service is serving with that
                      configuration. Without it, both halves measure the same
                      thing and the report will say so.
  SEED_MANIFEST       path to the seed manifest (default benchmarks/seed-manifest.json)
  K6_PROMETHEUS_RW_SERVER_URL  export k6 metrics to Prometheus as well

OUTPUT  (benchmarks/results/<timestamp>/)
  cache-ab.md     comparison table, divergence chart, stampede result, verdict
  cache-ab.json   the same, machine-readable

ON A SERVICE THAT HAS NO CACHE YET
  Phase 4 is what wires up Valkey. Before that, CACHE_ENABLED is read and
  ignored, so both halves of the A/B are the same code path. This script detects
  that (identical numbers, no cache metrics, no Valkey traffic) and says so
  plainly instead of reporting a meaningless 0% improvement as though it were a
  finding.

EXAMPLES
  scripts/bench-cache.sh --impl go
  scripts/bench-cache.sh --impl go --no-ramp --no-stampede --rate 300 --duration 60s
  scripts/bench-cache.sh --impl all --seed-size small --warmup 20
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)          IMPL_ARG="${2:?}"; shift 2 ;;
    --rate)          RATE="${2:?}"; shift 2 ;;
    --duration)      DURATION="${2:?}"; shift 2 ;;
    --rates)         RATES="${2:?}"; shift 2 ;;
    --step-duration) STEP_DURATION_S="${2:?}"; shift 2 ;;
    --stampede-n)    STAMPEDE_N="${2:?}"; shift 2 ;;
    --hot-pages)     HOT_PAGES="${2:?}"; shift 2 ;;
    --warmup)        WARMUP_S="${2:?}"; shift 2 ;;
    --warmup-rate)   WARMUP_RATE="${2:?}"; shift 2 ;;
    --seed-size)     SEED_SIZE="${2:?}"; shift 2 ;;
    --no-reseed)     RESEED=0; shift ;;
    --no-ramp)       DO_RAMP=0; shift ;;
    --no-stampede)   DO_STAMPEDE=0; shift ;;
    --no-restart)    NO_RESTART=1; shift ;;
    --slo-p95)       SLO_P95_MS="${2:?}"; shift 2 ;;
    --base-url)      BASE_URL_OVERRIDE="${2:?}"; NO_RESTART=1; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

declare -a IMPLS=()
if [[ "${IMPL_ARG}" == "all" ]]; then IMPLS=("${IMPLS_ALL[@]}");
else
  IFS=',' read -r -a IMPLS <<< "${IMPL_ARG}"
  for i in "${IMPLS[@]}"; do is_impl "$i" || die "unknown implementation '$i'"; done
fi

require_jq
# Docker is only needed to drive the compose containers. With --base-url the
# caller owns the lifecycle, so do not demand a daemon we will never talk to.
[[ -n "${BASE_URL_OVERRIDE}" ]] || require_docker
detect_k6

# Single source of truth for "where do I send traffic".
target_base_url() {
  if [[ -n "${BASE_URL_OVERRIDE}" ]]; then printf '%s' "${BASE_URL_OVERRIDE}"
  else impl_base_url "$1"; fi
}

RESULTS_DIR="$(new_results_dir benchmarks/results)"
ABS_RESULTS="${REPO_ROOT}/${RESULTS_DIR}"

section "cache A/B"
info "impls    ${IMPLS[*]}"
info "results  ${RESULTS_DIR}"

capture_environment "${ABS_RESULTS}/environment.txt"

HAVE_PGSS=0
if ensure_pg_stat_statements; then
  HAVE_PGSS=1
  ok "pg_stat_statements available — database query counts will be measured"
else
  warn "pg_stat_statements is NOT available"
  step "This removes the single most convincing number from the report."
  step "docker-compose.yml already sets shared_preload_libraries=pg_stat_statements;"
  step "if it is missing, the Postgres container was started without that flag."
  step "Fix:  docker compose down postgres && docker compose up -d postgres"
fi

HAVE_VALKEY=0
if valkey_available; then HAVE_VALKEY=1; ok "valkey reachable"; else
  warn "valkey is not reachable — cache hit ratio will fall back to app metrics only"
  step "Start it:  docker compose -f docker-compose.infra.yml up -d valkey"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Restart a service with a given CACHE_ENABLED value.
# ─────────────────────────────────────────────────────────────────────────────
# docker-compose.yml already parameterises it as ${CACHE_ENABLED:-true}, which
# is exactly what makes this A/B possible without editing any YAML: set the
# variable in the environment and recreate the one container.
restart_with_cache() {
  local impl="$1" enabled="$2"
  local svc; svc="$(impl_service "${impl}")"
  local base; base="$(target_base_url "${impl}")"

  if (( NO_RESTART )); then
    # Hook for services this script does not own (--base-url, a binary run
    # outside Docker, a remote host). The command is invoked with "true" or
    # "false" and must not return until the service is serving with that
    # configuration. Without it, --no-restart means BOTH halves measure the
    # same thing — which the verdict logic will then correctly call out.
    if [[ -n "${CACHE_TOGGLE_HOOK:-}" ]]; then
      step "CACHE_TOGGLE_HOOK ${CACHE_TOGGLE_HOOK} ${enabled}"
      "${CACHE_TOGGLE_HOOK}" "${enabled}" \
        || die "CACHE_TOGGLE_HOOK failed for CACHE_ENABLED=${enabled}"
      wait_for_health "${base}" 120 || die "service not ready after CACHE_TOGGLE_HOOK"
    else
      step "--no-restart: leaving ${svc} as-is (CACHE_ENABLED is NOT being changed by this script)"
    fi
    return 0
  fi

  step "recreating ${svc} with CACHE_ENABLED=${enabled}"
  ( cd "${REPO_ROOT}" && CACHE_ENABLED="${enabled}" RATE_LIMIT_ENABLED=false \
      docker compose up -d --force-recreate --no-deps "${svc}" ) >/dev/null 2>&1 \
    || die "could not recreate ${svc} with CACHE_ENABLED=${enabled}"

  wait_for_health "${base}" 120 \
    || die_hint "${impl} did not become ready after restart" \
         "docker compose logs --tail=50 ${svc}"

  # Confirm the variable actually landed. A silent typo here would produce two
  # identical runs and a report claiming caching does nothing.
  local actual
  actual="$(docker inspect "$(impl_container "${impl}")" \
              --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | awk -F= '/^CACHE_ENABLED=/ {print $2}' | tail -1)"
  if [[ -n "${actual}" && "${actual}" != "${enabled}" ]]; then
    die "CACHE_ENABLED did not take effect: wanted ${enabled}, container has ${actual}"
  fi
  step "container env CACHE_ENABLED=${actual:-<unset>}"

  # RATE_LIMIT_ENABLED=false for both halves. A rate limiter that starts
  # returning 429s at high arrival rates would truncate the sweep in the same
  # place regardless of the cache, and mask the divergence we are here to see.
}

# ─────────────────────────────────────────────────────────────────────────────
# One measured configuration (cache on or off).
# ─────────────────────────────────────────────────────────────────────────────
# Echoes the metrics-file path on stdout; sends a side-car JSON of DB/cache/
# resource numbers to <label>-side.json.
run_config() {
  local impl="$1" cache="$2" mode="$3"   # mode: steady | ramp | stampede
  local base label container
  base="$(target_base_url "${impl}")"
  container="$(impl_container "${impl}")"
  label="${impl}-cache-${cache}-${mode}"

  # Identical data for BOTH halves. Deterministic regeneration is equivalent to
  # restoring a snapshot and needs no pg_dump plumbing.
  if (( RESEED )); then
    step "re-seeding (${SEED_SIZE}) — both halves must read identical rows"
    bash "${SCRIPT_DIR}/seed.sh" --size "${SEED_SIZE}" --truncate --quiet >/dev/null 2>&1 \
      || warn "re-seed failed — run scripts/seed.sh by hand to see why"
  fi

  # Warm-up, discarded. With the cache ON this also populates it — measuring a
  # cold cache against a warm database would flatter the uncached run.
  if [[ "${mode}" != "stampede" ]]; then
    warmup "${base}" "${WARMUP_S}" "${WARMUP_RATE}"
  else
    # The stampede needs the OPPOSITE: a guaranteed-cold key.
    step "flushing the cache so the key is genuinely cold"
    (( HAVE_VALKEY )) && valkey_flush || true
    sleep 1
  fi

  # Baselines, taken as late as possible so warm-up traffic is excluded.
  # No pg_before counterpart: pg_stat_statements_reset() zeroes the counters,
  # so the "before" value is 0 by construction and the delta is the raw total.
  local vk_hits_before=0 vk_miss_before=0
  if (( HAVE_PGSS )); then pg_stat_reset; fi
  if (( HAVE_VALKEY )); then
    vk_hits_before="$(valkey_stat keyspace_hits || echo 0)"
    vk_miss_before="$(valkey_stat keyspace_misses || echo 0)"
  fi
  local app_hits_before app_gets_before
  app_hits_before="$(scrape_metric_sum "${base}" 'cache_operations_total' 'result="hit"' || echo '')"
  app_gets_before="$(scrape_metric_sum "${base}" 'cache_operations_total' 'operation="get"' || echo '')"

  local statsfile="${ABS_RESULTS}/${label}-resources.txt"
  : > "${statsfile}"
  ( while true; do s="$(container_stats "${container}" 2>/dev/null || true)"; [[ -n "$s" ]] && echo "$s" >> "${statsfile}"; sleep 2; done ) &
  local sampler=$!

  local -a env_args=(
    -e "BASE_URL=${base}"
    -e "IMPL=${impl}"
    -e "RESULTS_DIR=${RESULTS_DIR}"
    -e "RUN_LABEL=${label}"
    -e "AB_MODE=${mode}"
    -e "RATE=${RATE}"
    -e "DURATION=${DURATION}"
    -e "RATES=${RATES}"
    -e "STEP_DURATION_S=${STEP_DURATION_S}"
    -e "STAMPEDE_N=${STAMPEDE_N}"
    -e "CACHE_HOT_PAGES=${HOT_PAGES}"
    -e "SEED_MANIFEST=$(seed_manifest_arg)"
  )

  local t0 t1 rc=0
  t0="$(date +%s)"
  k6_run tests/load/cache-ab.js "${env_args[@]}" --no-usage-report --quiet \
    >"${ABS_RESULTS}/${label}-k6.log" 2>&1 || rc=$?
  t1="$(date +%s)"
  kill "${sampler}" >/dev/null 2>&1 || true
  wait "${sampler}" 2>/dev/null || true

  if (( rc == 107 )); then
    fail "${label}: k6 script exception"
    grep -m3 'level=error' "${ABS_RESULTS}/${label}-k6.log" | sed 's/^/      /' >&2 || true
    echo ""; return 1
  fi

  local elapsed=$(( t1 - t0 )); (( elapsed < 1 )) && elapsed=1

  # Deltas.
  local pg_total=0 pg_select=0
  if (( HAVE_PGSS )); then
    pg_total="$(pg_total_calls)"
    pg_select="$(pg_select_calls)"
    pg_top_queries 12 > "${ABS_RESULTS}/${label}-top-queries.txt" 2>/dev/null || true
  fi
  local vk_hits=0 vk_miss=0
  if (( HAVE_VALKEY )); then
    vk_hits=$(( $(valkey_stat keyspace_hits || echo 0) - vk_hits_before ))
    vk_miss=$(( $(valkey_stat keyspace_misses || echo 0) - vk_miss_before ))
  fi
  local app_hits app_gets app_ratio=""
  app_hits="$(scrape_metric_sum "${base}" 'cache_operations_total' 'result="hit"' || echo '')"
  app_gets="$(scrape_metric_sum "${base}" 'cache_operations_total' 'operation="get"' || echo '')"
  if [[ -n "${app_hits}" && -n "${app_gets}" ]]; then
    app_ratio="$(awk -v a="${app_hits}" -v ab="${app_hits_before:-0}" -v g="${app_gets}" -v gb="${app_gets_before:-0}" \
      'BEGIN { dg = g-gb; if (dg <= 0) exit; printf "%.4f", (a-ab)/dg }')"
  fi
  local stampede_waits
  stampede_waits="$(scrape_metric_sum "${base}" 'cache_stampede_lock_waits_total' || echo '')"

  local cpu_med rss_med rss_max
  if [[ -s "${statsfile}" ]]; then
    cpu_med="$(awk '{print $1}' "${statsfile}" | median)"
    rss_med="$(awk '{print $2}' "${statsfile}" | median)"
    rss_max="$(awk '{print $2}' "${statsfile}" | sort -g | tail -1)"
  fi

  local mfile
  mfile="$(ls -1 "${ABS_RESULTS}/${label}-cache-ab-"*-metrics.json 2>/dev/null | head -1 || true)"
  [[ -z "${mfile}" ]] && { fail "${label}: no metrics file produced"; echo ""; return 1; }

  local vk_ratio=""
  if (( HAVE_VALKEY )) && (( vk_hits + vk_miss > 0 )); then
    vk_ratio="$(fdiv "${vk_hits}" $(( vk_hits + vk_miss )))"
  fi

  local tmp="${mfile}.tmp"
  jq --arg cache "${cache}" --arg mode "${mode}" \
     --argjson elapsed "${elapsed}" \
     --argjson pgTotal "${pg_total:-0}" --argjson pgSelect "${pg_select:-0}" \
     --argjson pgss "${HAVE_PGSS}" \
     --argjson vkHits "${vk_hits:-0}" --argjson vkMiss "${vk_miss:-0}" \
     --arg vkRatio "${vk_ratio}" --arg appRatio "${app_ratio}" \
     --arg stampedeWaits "${stampede_waits}" \
     --argjson cpu "${cpu_med:-null}" --argjson rssMed "${rss_med:-null}" --argjson rssMax "${rss_max:-null}" \
     --argjson sloP95 "${SLO_P95_MS}" \
     '.cacheEnabled = ($cache == "on")
      | .abMode = $mode
      | .wallSeconds = $elapsed
      | .db = {
          measured: ($pgss == 1),
          totalCalls: $pgTotal,
          selectCalls: $pgSelect,
          callsPerSecond: (if $elapsed > 0 then ($pgTotal / $elapsed) else null end),
          callsPerRequest: (if (.http.requests // 0) > 0 then ($pgTotal / .http.requests) else null end)
        }
      | .cache = {
          valkeyHits: $vkHits, valkeyMisses: $vkMiss,
          valkeyHitRatio: (if $vkRatio == "" then null else ($vkRatio|tonumber) end),
          appHitRatio: (if $appRatio == "" then null else ($appRatio|tonumber) end),
          stampedeLockWaits: (if $stampedeWaits == "" then null else ($stampedeWaits|tonumber) end)
        }
      | .resources = {cpuPercentMedian: $cpu, rssBytesMedian: $rssMed, rssBytesMax: $rssMax}
      | .maxRateUnderSLO = (
          [ (.steps // {}) | to_entries[] | .value
            | select((.p95 // 1e9) < $sloP95)
            | select((.failRate // 0) < 0.01)
            | .rate ] | max // null)
      ' "${mfile}" > "${tmp}" && mv "${tmp}" "${mfile}"

  local p95 dbps
  p95="$(jq -r '.http.p95 // "—"' "${mfile}")"
  dbps="$(jq -r 'if .db.callsPerSecond then (.db.callsPerSecond|floor|tostring) else "n/a" end' "${mfile}")"
  ok "${label}: p95 ${p95} ms, $(jq -r '.http.requests' "${mfile}") requests, ${dbps} db-queries/s"
  echo "${mfile}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-implementation A/B
# ─────────────────────────────────────────────────────────────────────────────
declare -a REPORT_IMPLS=()
declare -A F_OFF_STEADY F_ON_STEADY F_OFF_RAMP F_ON_RAMP F_OFF_STAMP F_ON_STAMP

for impl in "${IMPLS[@]}"; do
  section "${impl}"
  base="$(target_base_url "${impl}")"

  if [[ -n "${BASE_URL_OVERRIDE}" ]]; then
    warn "--base-url: this script manages nothing. YOU must set CACHE_ENABLED"
    step "false before the OFF half and true before the ON half, or both halves"
    step "will measure the same configuration and the report will be worthless."
    step "target: ${base}"
  else
    # Rule 1 still applies: the other four would contend for the same Postgres.
    for other in "${IMPLS_ALL[@]}"; do
      [[ "${other}" == "${impl}" ]] && continue
      c="$(impl_container "${other}")"
      container_running "${c}" && { step "stopping ${c} (one service at a time)"; docker stop "${c}" >/dev/null 2>&1 || true; }
    done
    compose up -d "$(impl_service "${impl}")" >/dev/null 2>&1 || true
  fi

  if ! wait_for_health "${base}" 120; then
    fail "${impl}: never became ready at ${base}"; continue
  fi
  if ! check_implemented "${base}" "${impl}"; then
    step "Refusing to A/B the 501 error path. Implement Phase 1 first."
    continue
  fi

  # ── cache OFF ──
  section "${impl}: CACHE_ENABLED=false"
  restart_with_cache "${impl}" "false"
  F_OFF_STEADY["${impl}"]="$(run_config "${impl}" off steady || true)"
  (( DO_RAMP ))     && F_OFF_RAMP["${impl}"]="$(run_config "${impl}" off ramp || true)"
  (( DO_STAMPEDE )) && F_OFF_STAMP["${impl}"]="$(run_config "${impl}" off stampede || true)"

  # ── cache ON ──
  section "${impl}: CACHE_ENABLED=true"
  restart_with_cache "${impl}" "true"
  F_ON_STEADY["${impl}"]="$(run_config "${impl}" on steady || true)"
  (( DO_RAMP ))     && F_ON_RAMP["${impl}"]="$(run_config "${impl}" on ramp || true)"
  (( DO_STAMPEDE )) && F_ON_STAMP["${impl}"]="$(run_config "${impl}" on stampede || true)"

  [[ -n "${F_OFF_STEADY[${impl}]:-}" && -n "${F_ON_STEADY[${impl}]:-}" ]] && REPORT_IMPLS+=("${impl}")
done

if (( ${#REPORT_IMPLS[@]} == 0 )); then
  section "no results"
  fail "no implementation produced a comparable pair of runs"
  cat >&2 <<'EOF'

   The usual reason is that /api/v1/tasks still answers 501 (the skeleton
   catch-all). Caching cannot be measured on an endpoint that does not exist.
   Implement Phase 1, then Phase 4, then come back.

   To prove the harness works with no service at all:
     node tests/load/tools/stub-server.mjs --port 8099 --cache &
     k6 run tests/load/cache-ab.js -e BASE_URL=http://localhost:8099 \
         -e AB_MODE=ramp -e RATES=50,100 -e STEP_DURATION_S=5
EOF
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────────────────
section "report"
JSON_OUT="${ABS_RESULTS}/cache-ab.json"
MD_OUT="${ABS_RESULTS}/cache-ab.md"

# Merge every per-run file into one object per impl.
{
  echo '{'
  printf '  "schema": "taskflow.cache-ab.v1",\n'
  printf '  "generatedAt": %s,\n' "$(jq -Rn --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '$d')"
  printf '  "config": {"rate": %s, "duration": "%s", "warmupSeconds": %s, "seedSize": "%s", "hotPages": %s, "stampedeN": %s, "sloP95Ms": %s, "rates": "%s"},\n' \
    "${RATE}" "${DURATION}" "${WARMUP_S}" "${SEED_SIZE}" "${HOT_PAGES}" "${STAMPEDE_N}" "${SLO_P95_MS}" "${RATES}"
  printf '  "pgStatStatements": %s,\n' "$( ((HAVE_PGSS)) && echo true || echo false )"
  printf '  "implementations": {\n'
  first=1
  for impl in "${REPORT_IMPLS[@]}"; do
    (( first )) || printf ',\n'; first=0
    printf '    "%s": {\n' "${impl}"
    printf '      "off": {"steady": %s, "ramp": %s, "stampede": %s},\n' \
      "$(cat "${F_OFF_STEADY[${impl}]}" 2>/dev/null || echo null)" \
      "$( [[ -n "${F_OFF_RAMP[${impl}]:-}" ]] && cat "${F_OFF_RAMP[${impl}]}" || echo null )" \
      "$( [[ -n "${F_OFF_STAMP[${impl}]:-}" ]] && cat "${F_OFF_STAMP[${impl}]}" || echo null )"
    printf '      "on": {"steady": %s, "ramp": %s, "stampede": %s}\n' \
      "$(cat "${F_ON_STEADY[${impl}]}" 2>/dev/null || echo null)" \
      "$( [[ -n "${F_ON_RAMP[${impl}]:-}" ]] && cat "${F_ON_RAMP[${impl}]}" || echo null )" \
      "$( [[ -n "${F_ON_STAMP[${impl}]:-}" ]] && cat "${F_ON_STAMP[${impl}]}" || echo null )"
    printf '    }'
  done
  printf '\n  }\n}\n'
} | jq '.' > "${JSON_OUT}"

# ── verdict: did caching actually do anything? ───────────────────────────────
# Guards against the two ways this report can be wrong:
#   (a) Phase 4 is not built, CACHE_ENABLED is read and ignored, and we would
#       otherwise publish "0% improvement" as though it were a measurement;
#   (b) the improvement is inside run-to-run noise and we would otherwise
#       publish it as a result.
verdict_for() {
  local impl="$1"
  # Look at p50 AND p95, not just p95. A cache that removes a database
  # round-trip on every hit can move the median enormously while barely
  # touching p95 (the tail is still whatever the misses and the slowest
  # requests cost). Judging on p95 alone reports an obviously-working cache as
  # "not implemented", which is exactly the wrong error to make in a report
  # whose whole job is to distinguish those two cases.
  jq -r --arg i "${impl}" --argjson noise 3 '
    .implementations[$i] as $x
    | ($x.off.steady.http.p95 // 0)            as $p95off
    | ($x.on.steady.http.p95 // 0)             as $p95on
    | ($x.off.steady.http.med // 0)            as $p50off
    | ($x.on.steady.http.med // 0)             as $p50on
    | ($x.off.steady.db.totalCalls // 0)       as $dboff
    | ($x.on.steady.db.totalCalls // 0)        as $dbon
    | ($x.on.steady.cache.valkeyHits // 0)     as $vk
    | ($x.on.steady.cache.appHitRatio)         as $app
    | (if $p95off > 0 then 100*($p95off-$p95on)/$p95off else 0 end) as $lat95
    | (if $p50off > 0 then 100*($p50off-$p50on)/$p50off else 0 end) as $lat50
    | ([($lat95|fabs), ($lat50|fabs)] | max)                        as $lat
    | (if $dboff > 0 then 100*($dboff-$dbon)/$dboff else 0 end)     as $db
    | if ($vk == 0 and $app == null and ($db|fabs) < $noise and $lat < $noise)
      then "NOT_IMPLEMENTED"
      elif $lat < $noise and ($db|fabs) < $noise
      then "NO_EFFECT"
      else "MEASURED" end' "${JSON_OUT}"
}

pctdelta() { # jq path a, jq path b → % reduction from a to b
  jq -r --arg i "$1" --arg a "$2" --arg b "$3" '
    .implementations[$i] as $x
    | ($x | getpath($a|split(".")) // null) as $va
    | ($x | getpath($b|split(".")) // null) as $vb
    | if $va == null or $vb == null or $va == 0 then "—"
      else ((100*($va-$vb)/$va) | .*10 | round / 10 | tostring + "%") end' "${JSON_OUT}"
}
getv() {
  jq -r --arg i "$1" --arg p "$2" '.implementations[$i] | getpath($p|split(".")) // "—"' "${JSON_OUT}"
}
# getv, rounded for display. Raw JSON doubles like 0.06666666666666667 in a
# report table are noise pretending to be precision.
getvr() { round_num "$(getv "$1" "$2")" "${3:-2}"; }

# The largest p95 across BOTH ramp files, so the two comparison charts share one
# scale. Independently auto-scaled charts placed next to each other are actively
# misleading — the whole point of drawing them together is that the bars are
# comparable.
shared_chart_max() {
  local a="$1" b="$2"
  jq -rn --slurpfile x "${a}" --slurpfile y "${b}" \
    '[ ($x[0].steps // {} | to_entries[] | .value.p95 // 0),
       ($y[0].steps // {} | to_entries[] | .value.p95 // 0) ] | max // 0' 2>/dev/null || echo 0
}

{
  echo "# Cache A/B — what Redis/Valkey buys"
  echo
  echo "- **generated** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **workload** read-heavy (85% \`GET /tasks\`, 15% \`GET /tasks/:id\`), ${HOT_PAGES} hot list pages"
  echo "- **single-point run** ${RATE} rps for ${DURATION}, after a ${WARMUP_S}s discarded warm-up"
  echo "- **dataset** \`--size ${SEED_SIZE}\`, deterministically re-seeded before every run"
  echo "- **rate limiting** disabled in both halves, so 429s cannot truncate the sweep"
  echo "- **load generator** k6 (open-loop \`constant-arrival-rate\`)"
  echo "- **DB query counts** $( ((HAVE_PGSS)) && echo 'from `pg_stat_statements`, reset immediately before each run' || echo '**unavailable** — `pg_stat_statements` was not installed')"
  echo
  echo "> Open-loop matters more here than anywhere else in the suite. A closed-loop"
  echo "> generator stops sending when the server stalls, so the **uncached** run —"
  echo "> the one that stalls — has its slow requests silently omitted from the"
  echo "> histogram. That biases the result *against* the cache, in a way that looks"
  echo "> like a careful measurement."
  echo

  for impl in "${REPORT_IMPLS[@]}"; do
    v="$(verdict_for "${impl}")"
    echo "## ${impl}"
    echo

    case "${v}" in
      NOT_IMPLEMENTED)
        echo "### ⚠ This service does not appear to implement caching yet"
        echo
        echo "Both halves of the A/B produced the same numbers, the app exposed no"
        echo "\`cache_operations_total\` metric, and Valkey recorded no keyspace hits."
        echo "The most likely explanation is that **Phase 4 is not built**: \`CACHE_ENABLED\`"
        echo "is passed into the container and then ignored, so both runs executed the"
        echo "identical code path."
        echo
        echo "Reporting this as \"0% improvement\" would be a category error — it is not a"
        echo "measurement of a cache, it is the absence of one. The table below is"
        echo "included only so you can confirm the two runs really were identical."
        echo
        ;;
      NO_EFFECT)
        echo "### Caching is wired up but made no measurable difference here"
        echo
        echo "Cache activity was observed, but neither latency nor database load moved"
        echo "by more than run-to-run noise. That is a legitimate result and usually"
        echo "means one of:"
        echo
        echo "- the arrival rate is far below the knee, so there was no queue to remove"
        echo "  (check the divergence chart — this is the expected shape at low load);"
        echo "- the hot set is too large for the TTL, so almost everything missed;"
        echo "- the query being cached was already served from Postgres' own buffer"
        echo "  cache in microseconds, and a network round-trip to Valkey costs about"
        echo "  the same."
        echo
        ;;
    esac

    echo "| metric | cache OFF | cache ON | change |"
    echo "|---|---|---|---|"
    printf '| p50 latency | %s ms | %s ms | %s |\n' \
      "$(getvr "${impl}" off.steady.http.med)" "$(getvr "${impl}" on.steady.http.med)" \
      "$(pctdelta "${impl}" off.steady.http.med on.steady.http.med) lower"
    printf '| **p95 latency** | **%s ms** | **%s ms** | **%s lower** |\n' \
      "$(getvr "${impl}" off.steady.http.p95)" "$(getvr "${impl}" on.steady.http.p95)" \
      "$(pctdelta "${impl}" off.steady.http.p95 on.steady.http.p95)"
    printf '| p99 latency | %s ms | %s ms | %s lower |\n' \
      "$(getvr "${impl}" off.steady.http.p99)" "$(getvr "${impl}" on.steady.http.p99)" \
      "$(pctdelta "${impl}" off.steady.http.p99 on.steady.http.p99)"
    printf '| requests served | %s | %s | |\n' \
      "$(getv "${impl}" off.steady.http.requests)" "$(getv "${impl}" on.steady.http.requests)"
    printf '| error rate | %s | %s | |\n' \
      "$(getvr "${impl}" off.steady.httpFailRate 4)" "$(getvr "${impl}" on.steady.httpFailRate 4)"
    if (( HAVE_PGSS )); then
      printf '| **DB queries (total)** | **%s** | **%s** | **%s fewer** |\n' \
        "$(getv "${impl}" off.steady.db.totalCalls)" "$(getv "${impl}" on.steady.db.totalCalls)" \
        "$(pctdelta "${impl}" off.steady.db.totalCalls on.steady.db.totalCalls)"
      printf '| DB queries/sec | %s | %s | %s fewer |\n' \
        "$(getvr "${impl}" off.steady.db.callsPerSecond 1)" "$(getvr "${impl}" on.steady.db.callsPerSecond 1)" \
        "$(pctdelta "${impl}" off.steady.db.callsPerSecond on.steady.db.callsPerSecond)"
      printf '| DB queries per request | %s | %s | |\n' \
        "$(getvr "${impl}" off.steady.db.callsPerRequest 3)" "$(getvr "${impl}" on.steady.db.callsPerRequest 3)"
    fi
    printf '| CPU (median %%) | %s | %s | |\n' \
      "$(getvr "${impl}" off.steady.resources.cpuPercentMedian 1)" "$(getvr "${impl}" on.steady.resources.cpuPercentMedian 1)"
    printf '| RSS (median) | %s | %s | |\n' \
      "$(fmt_bytes "$(getv "${impl}" off.steady.resources.rssBytesMedian)")" \
      "$(fmt_bytes "$(getv "${impl}" on.steady.resources.rssBytesMedian)")"
    printf '| cache hit ratio (Valkey keyspace) | n/a | %s | |\n' "$(getvr "${impl}" on.steady.cache.valkeyHitRatio 4)"
    printf '| cache hit ratio (app metric) | n/a | %s | |\n' "$(getvr "${impl}" on.steady.cache.appHitRatio 4)"
    echo

    db_drop="$(jq -r --arg i "${impl}" '
        .implementations[$i] as $x
        | (($x.off.steady.db.totalCalls // 0)) as $a | (($x.on.steady.db.totalCalls // 0)) as $b
        | if $a > 0 then (100*($a-$b)/$a) else 0 end' "${JSON_OUT}")"
    db_meaningful="$(awk -v d="${db_drop}" 'BEGIN { print (d > 5) ? 1 : 0 }')"
    if [[ "${v}" == "MEASURED" ]] && (( HAVE_PGSS )) && [[ "${db_meaningful}" == "1" ]]; then
      echo "**The number to quote is the database one.** \"p95 improved\" invites an"
      echo "argument about noise; \"the database served $(pctdelta "${impl}" off.steady.db.totalCalls on.steady.db.totalCalls) fewer queries\" is a count, taken"
      echo "on the database rather than on the client, and it maps directly onto"
      echo "capacity you did not have to buy."
      echo
    fi

    # ── divergence chart ──
    off_ramp="${F_OFF_RAMP[${impl}]:-}"; on_ramp="${F_ON_RAMP[${impl}]:-}"
    if [[ -n "${off_ramp}" && -n "${on_ramp}" ]] && jq -e '.steps' "${off_ramp}" >/dev/null 2>&1; then
      echo "### Where the curves diverge"
      echo
      echo "Caching often buys almost nothing at low load and an enormous amount past"
      echo "the knee. **That crossover is the real lesson**, and a single-rate comparison"
      echo "cannot show it. Below, p95 as a function of arrival rate:"
      echo
      cmax="$(shared_chart_max "${off_ramp}" "${on_ramp}")"
      echo '```'
      printf '  cache OFF — p95 vs arrival rate   (both charts share one scale, 0..%s ms)\n' "$(round_num "${cmax}" 1)"
      jq -r '.steps | to_entries | sort_by(.value.rate)[] | "\(.value.rate) \(.value.p95 // 0)"' "${off_ramp}" | chart_ascii 40 ms "${cmax}"
      printf '\n  cache ON  — p95 vs arrival rate\n'
      jq -r '.steps | to_entries | sort_by(.value.rate)[] | "\(.value.rate) \(.value.p95 // 0)"' "${on_ramp}" | chart_ascii 40 ms "${cmax}"
      echo '```'
      echo
      echo "| arrival rate | p95 OFF | p95 ON | p99 OFF | p99 ON | speed-up |"
      echo "|---|---|---|---|---|---|"
      jq -rn --slurpfile a "${off_ramp}" --slurpfile b "${on_ramp}" '
        ($a[0].steps // {}) as $off | ($b[0].steps // {}) as $on
        | [$off | keys_unsorted[]] | sort_by(tonumber)[]
        | . as $k
        | ($off[$k].p95 // null) as $po | ($on[$k].p95 // null) as $pn
        | (def r1: if . == null then "—" else (.*10|round)/10|tostring end;
           "| \($k) | \($po|r1) ms | \($pn|r1) ms | \($off[$k].p99|r1) ms | \($on[$k].p99|r1) ms | " +
           (if $po and $pn and $pn > 0 then ((($po/$pn)*10|round)/10|tostring) + "x" else "—" end) + " |")
      ' 2>/dev/null || echo "| | | | | | |"
      echo
      off_cap="$(getv "${impl}" off.ramp.maxRateUnderSLO)"
      on_cap="$(getv "${impl}" on.ramp.maxRateUnderSLO)"
      echo "**Capacity under the ${SLO_P95_MS} ms p95 budget:** ${off_cap} rps without the cache,"
      echo "${on_cap} rps with it. This is the number to size a fleet from — not peak"
      echo "throughput, which you can always increase by accepting worse latency."
      echo
    fi

    # ── stampede ──
    off_st="${F_OFF_STAMP[${impl}]:-}"; on_st="${F_ON_STAMP[${impl}]:-}"
    if [[ -n "${off_st}" && -n "${on_st}" ]]; then
      echo "### Cache stampede"
      echo
      echo "${STAMPEDE_N} requests fired simultaneously at a single **cold** key (the cache was"
      echo "flushed immediately beforehand). Every one of them misses at t=0."
      echo
      echo "Without protection all ${STAMPEDE_N} go to the database for the same row — the"
      echo "thundering herd. A stampede lock (\`SET key NX\`) lets exactly one request"
      echo "through to the origin; the rest wait briefly and read the value it wrote."
      echo
      echo "| | cache OFF | cache ON |"
      echo "|---|---|---|"
      # endpoints."GET /tasks".count is the WORKLOAD's request count. http.requests
    # would also include setup()'s login and task-discovery calls, which would
    # make the stampede look larger than it was.
    printf '| requests fired | %s | %s |\n' \
      "$(getv "${impl}" 'off.stampede.endpoints.GET /tasks.count')" \
      "$(getv "${impl}" 'on.stampede.endpoints.GET /tasks.count')"
      if (( HAVE_PGSS )); then
        printf '| **origin (DB) queries** | **%s** | **%s** |\n' \
          "$(getv "${impl}" off.stampede.db.totalCalls)" "$(getv "${impl}" on.stampede.db.totalCalls)"
      fi
      printf '| p95 | %s ms | %s ms |\n' "$(getvr "${impl}" off.stampede.http.p95)" "$(getvr "${impl}" on.stampede.http.p95)"
      printf '| p99 | %s ms | %s ms |\n' "$(getvr "${impl}" off.stampede.http.p99)" "$(getvr "${impl}" on.stampede.http.p99)"
      printf '| max | %s ms | %s ms |\n' "$(getvr "${impl}" off.stampede.http.max)" "$(getvr "${impl}" on.stampede.http.max)"
      printf '| stampede lock waits | %s | %s |\n' \
        "$(getv "${impl}" off.stampede.cache.stampedeLockWaits)" "$(getv "${impl}" on.stampede.cache.stampedeLockWaits)"
      echo
      echo "Read the origin-query count as \"≈1 vs ≈${STAMPEDE_N}\", not as an exact figure. k6"
      echo "starts its VUs within a few milliseconds of each other rather than at the"
      echo "same instant, so a fast origin can serve a handful of requests before the"
      echo "first \`SET\` lands even when the lock works correctly."
      echo
      echo "If both columns show ~${STAMPEDE_N} origin queries, the cache-aside path has **no"
      echo "stampede lock** — which is the default behaviour of a naive"
      echo "\`get → miss → query → set\` implementation, and the reason the lock is a"
      echo "separate item in the Phase 4 checklist."
      echo
    fi
  done

  echo "## Caveats"
  echo
  echo "- **The hit ratio was chosen, not discovered.** The workload touches"
  echo "  ${HOT_PAGES} hot list pages. Point it at one page and the cache looks perfect;"
  echo "  point it at ten thousand and it looks useless. The number here is meant to"
  echo "  resemble the Zipfian shape of real traffic; it is still an assumption."
  echo "- Caching helps **reads**. The write path is unaffected at best and slightly"
  echo "  slower at worst, because every write must also invalidate. Benchmarking"
  echo "  \`write-heavy.js\` with the cache on is a useful sanity check, not a win."
  echo "- A cache trades **staleness** for latency. These numbers do not measure that"
  echo "  cost; \`CACHE_TTL_TASK_LIST=60\` means a list can be up to a minute out of"
  echo "  date, which is a product decision rather than a performance one."
  echo "- Both halves ran on the same host as the load generator."
  echo
  echo "## Environment"
  echo
  echo '```'
  cat "${ABS_RESULTS}/environment.txt"
  echo '```'
} > "${MD_OUT}"

ok "cache-ab.md    ${RESULTS_DIR}/cache-ab.md"
ok "cache-ab.json  ${RESULTS_DIR}/cache-ab.json"
for impl in "${REPORT_IMPLS[@]}"; do
  case "$(verdict_for "${impl}")" in
    NOT_IMPLEMENTED) warn "${impl}: caching does not appear to be implemented — report says so plainly" ;;
    NO_EFFECT)       warn "${impl}: cache active but no measurable effect at this load" ;;
    MEASURED)        ok   "${impl}: measurable cache effect recorded" ;;
  esac
done
