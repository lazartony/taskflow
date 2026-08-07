#!/usr/bin/env bash
# Shared helpers for the TaskFlow benchmark / profiling scripts.
#
# Sourced, never executed:  source "$(dirname "$0")/lib/common.sh"
#
# Everything here is written to fail loudly and early. A benchmark harness that
# limps along with a missing prerequisite produces numbers that look fine and
# mean nothing, which is strictly worse than not running at all.

# ─────────────────────────────────────────────────────────────────────────────
# Interpreter
# ─────────────────────────────────────────────────────────────────────────────
#
# These scripts use associative arrays (`declare -A`) and `mapfile`, both of
# which arrived in bash 4.0. macOS still ships bash 3.2 as /bin/bash — Apple
# froze it at the last GPLv2 release — so this is the single most likely reason
# a Mac user sees something strange. Checked here rather than left to chance:
# bash 3.2 does not fail cleanly on either feature. `mapfile: command not found`
# goes to stderr and returns non-zero, but a script that carries on regardless
# reports success having done nothing, which is the worst outcome available.
# Called by the scripts that genuinely need bash 4 (the ones keeping keyed
# tables of per-implementation results). It is NOT called unconditionally: most
# of the tooling runs perfectly on 3.2, and refusing to run `make validate` on a
# stock Mac would trade a real bug for an invented one.
require_bash4() {
  if [[ -n "${BASH_VERSINFO:-}" ]] && (( BASH_VERSINFO[0] >= 4 )); then
    return 0
  fi
  printf 'error: %s needs bash 4.0 or newer (found %s).\n' \
    "${0##*/}" "${BASH_VERSION:-not bash}" >&2
  printf '  It keeps results in an associative array, which bash 3.2 has not got.\n' >&2
  printf '  macOS still ships 3.2 as /bin/bash — Apple froze it at the last GPLv2\n' >&2
  printf '  release. Install a current bash and put it ahead on PATH:\n\n' >&2
  printf '    brew install bash\n' >&2
  printf '    exec $SHELL -l          # then re-run\n\n' >&2
  printf '  Everything else this project needs runs in a container; this is the\n' >&2
  printf '  one host tool with a version floor.\n' >&2
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Repository layout
# ─────────────────────────────────────────────────────────────────────────────
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="${REPO_ROOT:-$(cd "${COMMON_SH_DIR}/../.." && pwd)}"

export IMPLS_ALL=(go rust python csharp typescript)

# impl -> host port
impl_port() {
  case "$1" in
    go)         echo 8001 ;;
    rust)       echo 8002 ;;
    python)     echo 8003 ;;
    csharp)     echo 8004 ;;
    typescript) echo 8005 ;;
    *) return 1 ;;
  esac
}

# impl -> docker compose service name
impl_service() {
  case "$1" in
    go|rust|python|csharp|typescript) echo "${1}-api" ;;
    *) return 1 ;;
  esac
}

# impl -> container name (as pinned in docker-compose.yml)
impl_container() {
  case "$1" in
    go|rust|python|csharp|typescript) echo "taskflow-${1}" ;;
    *) return 1 ;;
  esac
}

impl_base_url() {
  local port; port="$(impl_port "$1")" || return 1
  echo "http://localhost:${port}"
}

is_impl() {
  local i
  for i in "${IMPLS_ALL[@]}"; do [[ "$i" == "$1" ]] && return 0; done
  return 1
}

export PG_CONTAINER="${PG_CONTAINER:-taskflow-db}"
export VALKEY_CONTAINER="${VALKEY_CONTAINER:-taskflow-valkey}"
export DATABASE_URL="${DATABASE_URL:-postgresql://postgres:password@localhost:5432/taskflow_dev}"
export K6_IMAGE="${K6_IMAGE:-grafana/k6:1.8.0}"

# ─────────────────────────────────────────────────────────────────────────────
# Colour + logging
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi
export C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_CYAN

log()     { printf '%s\n' "$*" >&2; }
info()    { printf '%s  %s%s\n' "${C_BLUE}··${C_RESET}" "$*" "" >&2; }
ok()      { printf '%s  %s\n' "${C_GREEN}PASS${C_RESET}" "$*" >&2; }
warn()    { printf '%s  %s\n' "${C_YELLOW}WARN${C_RESET}" "$*" >&2; }
fail()    { printf '%s  %s\n' "${C_RED}FAIL${C_RESET}" "$*" >&2; }
step()    { printf '%s\n' "${C_DIM}   → $*${C_RESET}" >&2; }

section() {
  printf '\n%s%s%s\n' "${C_BOLD}${C_CYAN}" "── $* $(printf '─%.0s' $(seq 1 $(( 70 - ${#1} > 0 ? 70 - ${#1} : 3 ))))" "${C_RESET}" >&2
}

die() { fail "$*"; exit 1; }

# die with a remediation hint on its own line — used for missing prerequisites
die_hint() {
  fail "$1"; shift
  local l; for l in "$@"; do printf '      %s%s%s\n' "${C_DIM}" "$l" "${C_RESET}" >&2; done
  exit 1
}

require_cmd() {
  local cmd="$1"; shift
  command -v "$cmd" >/dev/null 2>&1 && return 0
  die_hint "required command not found: ${cmd}" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Timestamps and result directories
# ─────────────────────────────────────────────────────────────────────────────
timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# Create (once per script run) the results directory everything writes into.
# RESULTS_TS may be pre-set by a caller so several scripts share one directory.
new_results_dir() {
  local base="${1:-benchmarks/results}"
  export RESULTS_TS="${RESULTS_TS:-$(timestamp)}"
  export RESULTS_DIR="${base}/${RESULTS_TS}"
  mkdir -p "${REPO_ROOT}/${RESULTS_DIR}"
  printf '%s' "${RESULTS_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker / compose
# ─────────────────────────────────────────────────────────────────────────────
have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die_hint "docker is not installed" \
    "The benchmark harness drives the services through docker compose." \
    "Install Docker Engine 27+ : https://docs.docker.com/engine/install/"
  docker info >/dev/null 2>&1 || die_hint "the Docker daemon is not reachable" \
    "Start it (systemctl start docker / open Docker Desktop) and retry." \
    "If you are in a rootless setup, check DOCKER_HOST."
}

compose() {
  ( cd "${REPO_ROOT}" && docker compose "$@" )
}

container_running() {
  [[ -n "$(docker ps -q -f "name=^/${1}$" 2>/dev/null)" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# k6 — local binary preferred, Docker fallback
# ─────────────────────────────────────────────────────────────────────────────
#
# The Docker path bind-mounts the repository at /work and runs with the caller's
# UID so handleSummary() can write results the caller can actually read. It also
# uses --network host, because the scripts address the services as
# localhost:800x; without it, "localhost" inside the container is the container.
K6_MODE=""

detect_k6() {
  if [[ -n "${K6_MODE}" ]]; then return 0; fi
  if command -v k6 >/dev/null 2>&1; then
    K6_MODE="local"
    step "k6: local binary ($(k6 version 2>/dev/null | head -1))"
    return 0
  fi
  if have_docker; then
    K6_MODE="docker"
    step "k6: not installed locally — using ${K6_IMAGE} via Docker"
    return 0
  fi
  die_hint "k6 is not installed and Docker is not available" \
    "Install k6:      https://grafana.com/docs/k6/latest/set-up/install-k6/" \
    "  macOS:         brew install k6" \
    "  Debian/Ubuntu: sudo gpg -k && curl -s https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main' | sudo tee /etc/apt/sources.list.d/k6.list && sudo apt update && sudo apt install k6" \
    "Or run it through Docker (no install needed):" \
    "  docker run --rm -i --network host -v \"\$PWD:/work\" -w /work ${K6_IMAGE} run tests/load/smoke.js -e BASE_URL=http://localhost:8001"
}

# k6_run <script> [k6 args...]
#
# Adds the Prometheus remote-write output when K6_PROMETHEUS_RW_SERVER_URL is
# set, so load-test metrics land on the same Prometheus as the service metrics.
# A load-test p95 and a server-side p95 that disagree is itself a finding —
# usually queueing somewhere the server cannot see.
k6_run() {
  detect_k6
  local script="$1"; shift

  local -a out_args=()
  if [[ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]]; then
    out_args+=(--out experimental-prometheus-rw)
    step "prometheus remote-write → ${K6_PROMETHEUS_RW_SERVER_URL}"
  fi

  # Trend stats must be forwarded to the RW output explicitly, otherwise only
  # counters arrive and every latency panel is empty.
  export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(95),p(99),min,max,avg}"

  if [[ "${K6_MODE}" == "local" ]]; then
    ( cd "${REPO_ROOT}" && k6 run "${out_args[@]}" "$@" "${script}" )
  else
    local -a envs=()
    local v
    for v in $(env | grep -oE '^K6_[A-Z0-9_]+' || true); do envs+=(-e "$v"); done
    docker run --rm -i --network host \
      --user "$(id -u):$(id -g)" \
      -v "${REPO_ROOT}:/work" -w /work \
      "${envs[@]}" \
      "${K6_IMAGE}" run "${out_args[@]}" "$@" "${script}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Postgres
# ─────────────────────────────────────────────────────────────────────────────
#
# Prefer `docker exec` into the compose Postgres — it needs no local client and
# no exposed port. Fall back to a local psql against DATABASE_URL.
PSQL_MODE=""

detect_psql() {
  [[ -n "${PSQL_MODE}" ]] && return 0
  if [[ -n "${FORCE_LOCAL_PSQL:-}" ]] && command -v psql >/dev/null 2>&1; then
    PSQL_MODE="local"; return 0
  fi
  if have_docker && container_running "${PG_CONTAINER}"; then
    PSQL_MODE="docker"; return 0
  fi
  if command -v psql >/dev/null 2>&1; then
    PSQL_MODE="local"; return 0
  fi
  die_hint "cannot reach Postgres" \
    "Neither the ${PG_CONTAINER} container is running nor is psql installed." \
    "Start the stack:  docker compose up -d postgres" \
    "Or install a client:  apt install postgresql-client / brew install libpq"
}

# psql_q <sql>          → tuples only, unaligned, no headers
psql_q() {
  detect_psql
  if [[ "${PSQL_MODE}" == "docker" ]]; then
    docker exec -i "${PG_CONTAINER}" psql -U postgres -d taskflow_dev \
      -v ON_ERROR_STOP=1 -tAX -c "$1"
  else
    psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -tAX -c "$1"
  fi
}

# psql_file_stdin  — feed SQL on stdin, optional extra psql args
psql_stdin() {
  detect_psql
  if [[ "${PSQL_MODE}" == "docker" ]]; then
    docker exec -i "${PG_CONTAINER}" psql -U postgres -d taskflow_dev -v ON_ERROR_STOP=1 "$@"
  else
    psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 "$@"
  fi
}

pg_ready() { psql_q 'SELECT 1' >/dev/null 2>&1; }

# pg_stat_statements: the single most convincing measurement in the cache report.
# "p95 improved 40%" invites argument; "the database served 87% fewer queries"
# does not.
pg_stat_statements_available() {
  local n; n="$(psql_q "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo 0)"
  [[ "${n//[^0-9]/}" == "1" ]]
}

ensure_pg_stat_statements() {
  pg_stat_statements_available && return 0
  psql_q 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements' >/dev/null 2>&1 || true
  pg_stat_statements_available && return 0
  return 1
}

pg_stat_reset() { psql_q 'SELECT pg_stat_statements_reset()' >/dev/null; }

# Total statement executions since the last reset. SELECTs only where asked.
pg_total_calls() {
  psql_q "SELECT COALESCE(sum(calls),0)::bigint FROM pg_stat_statements" | tr -d '[:space:]'
}

pg_select_calls() {
  psql_q "SELECT COALESCE(sum(calls),0)::bigint FROM pg_stat_statements
          WHERE query ILIKE 'select%' AND query NOT ILIKE '%pg_stat_statements%'" | tr -d '[:space:]'
}

pg_top_queries() {
  local n="${1:-10}"
  psql_q "SELECT calls || ' | ' || round(mean_exec_time::numeric,3) || 'ms | ' ||
            regexp_replace(left(query, 110), '\s+', ' ', 'g')
          FROM pg_stat_statements
          WHERE query NOT ILIKE '%pg_stat_statements%'
          ORDER BY calls DESC LIMIT ${n}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Valkey / Redis
# ─────────────────────────────────────────────────────────────────────────────
valkey_cli() {
  if have_docker && container_running "${VALKEY_CONTAINER}"; then
    docker exec -i "${VALKEY_CONTAINER}" valkey-cli "$@"
  elif command -v valkey-cli >/dev/null 2>&1; then
    valkey-cli "$@"
  elif command -v redis-cli >/dev/null 2>&1; then
    redis-cli "$@"
  else
    return 1
  fi
}

valkey_available() { valkey_cli PING >/dev/null 2>&1; }

valkey_flush() { valkey_cli FLUSHALL >/dev/null 2>&1; }

# keyspace_hits / keyspace_misses from INFO stats — a server-side hit ratio that
# needs no application instrumentation. Less precise than cache_operations_total
# (it counts every key, not just the task cache) but always available.
valkey_stat() {
  valkey_cli INFO stats 2>/dev/null | tr -d '\r' | awk -F: -v k="$1" '$1==k {print $2}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Service health / capability probing
# ─────────────────────────────────────────────────────────────────────────────
http_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" 2>/dev/null || echo 000
}

wait_for_health() {
  local base="$1" timeout="${2:-90}" waited=0
  while (( waited < timeout )); do
    if [[ "$(http_status "${base}/api/v1/health/ready" 3)" == "200" ]]; then
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done
  return 1
}

# Returns 0 if /api/v1/tasks is still the 501 catch-all.
service_is_501() {
  local base="$1"
  # Unauthenticated request: 501 from the catch-all beats 401 from real auth,
  # because the skeleton mounts the catch-all before any auth middleware.
  local code; code="$(http_status "${base}/api/v1/tasks" 5)"
  [[ "${code}" == "501" ]]
}

# Fail fast, loudly, with the fix — instead of producing a report about 501s.
assert_implemented() {
  local base="$1" impl="${2:-service}"
  local code; code="$(http_status "${base}/api/v1/health/live" 5)"
  if [[ "${code}" != "200" ]]; then
    die_hint "${impl}: no healthy service at ${base} (GET /api/v1/health/live → ${code})" \
      "Start it:  docker compose up -d $(impl_service "${impl}" 2>/dev/null || echo "${impl}-api")" \
      "Check it:  docker compose logs --tail=50 $(impl_service "${impl}" 2>/dev/null || echo "${impl}-api")"
  fi
  if service_is_501 "${base}"; then
    die_hint "${impl}: service returns 501 — implement Phase 1 first" \
      "GET ${base}/api/v1/tasks answers 501 NOT_IMPLEMENTED, which means the" \
      "/auth and /tasks routes are still the skeleton catch-all in" \
      "cmd/server (see docs/learning-roadmap.md Phase 1)." \
      "Benchmarking it would measure the error path, so this run is refused." \
      "Override with ALLOW_501=1 if you genuinely want to profile the 501 path."
  fi
  return 0
}

# Non-fatal variant: prints the warning, returns 1.
check_implemented() {
  local base="$1" impl="${2:-service}"
  if service_is_501 "${base}"; then
    fail "${impl}: service returns 501 — implement Phase 1 first"
    step "GET ${base}/api/v1/tasks → 501 NOT_IMPLEMENTED (skeleton catch-all)"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Metrics scraping (Prometheus text format on the service, when it has one)
# ─────────────────────────────────────────────────────────────────────────────
# Sum every sample of a metric family, ignoring labels. Returns "" if absent.
scrape_metric_sum() {
  local base="$1" metric="$2" filter="${3:-}"
  local body; body="$(curl -s --max-time 5 "${base}/metrics" 2>/dev/null)" || return 1
  [[ -z "${body}" ]] && return 1
  printf '%s\n' "${body}" | awk -v m="${metric}" -v f="${filter}" '
    /^#/ { next }
    index($0, m) == 1 {
      if (f != "" && index($0, f) == 0) next
      s += $NF; n++
    }
    END { if (n > 0) printf "%.6f", s; }
  '
}

service_exposes_metrics() {
  local body; body="$(curl -s --max-time 5 "${1}/metrics" 2>/dev/null)" || return 1
  [[ -n "${body}" && "${body}" == *"# HELP"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Container resource sampling
# ─────────────────────────────────────────────────────────────────────────────
# CPU% and RSS for a container, as a "cpu_pct rss_bytes" pair. Empty on failure.
container_stats() {
  local name="$1"
  have_docker || return 1
  container_running "${name}" || return 1
  docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "${name}" 2>/dev/null \
    | awk '{
        gsub(/%/, "", $1); cpu = $1;
        mem = $2; unit = mem;
        gsub(/[0-9.]/, "", unit); gsub(/[^0-9.]/, "", mem);
        mult = 1;
        if (unit ~ /^KiB/) mult = 1024;
        else if (unit ~ /^MiB/) mult = 1024*1024;
        else if (unit ~ /^GiB/) mult = 1024*1024*1024;
        else if (unit ~ /^kB/)  mult = 1000;
        else if (unit ~ /^MB/)  mult = 1000*1000;
        else if (unit ~ /^GB/)  mult = 1000*1000*1000;
        printf "%s %.0f", cpu, mem * mult;
      }'
}

# CPU limit (nanocpus) and memory limit (bytes) as declared to Docker.
container_limits() {
  local name="$1"
  docker inspect --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.CpuQuota}} {{.HostConfig.CpuPeriod}}' \
    "${name}" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Small numeric helpers (awk — no bc dependency)
# ─────────────────────────────────────────────────────────────────────────────
fdiv()  { awk -v a="$1" -v b="$2" 'BEGIN { if (b+0==0) print "0"; else printf "%.4f", a/b }'; }
fpct()  { awk -v a="$1" -v b="$2" 'BEGIN { if (b+0==0) print "0.0"; else printf "%.1f", 100*(a/b) }'; }
# Percentage reduction from a to b (positive = b is smaller = improvement).
fdelta_pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (a+0==0) print "0.0"; else printf "%.1f", 100*(a-b)/a }'; }
fmt_bytes() { awk -v b="$1" 'BEGIN { if (b+0==0) { print "—"; exit } split("B KiB MiB GiB", u, " "); i=1; while (b>=1024 && i<4) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'; }
# Round for display. Passes through "—" and other non-numbers untouched, so
# report templates do not have to special-case missing values.
round_num() {
  local v="$1" d="${2:-2}"
  [[ "${v}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || { printf '%s' "${v}"; return; }
  awk -v v="${v}" -v d="${d}" 'BEGIN { printf "%.*f", d, v }'
}

# median of numbers on stdin
median() { sort -g | awk '{a[NR]=$1} END { if (NR==0) { print ""; exit } if (NR%2) print a[(NR+1)/2]; else printf "%.3f", (a[NR/2]+a[NR/2+1])/2 }'; }
# population stddev of numbers on stdin
stddev() { awk '{x[NR]=$1; s+=$1} END { if (NR<2) { print "0.000"; exit } m=s/NR; for (i=1;i<=NR;i++) v+=(x[i]-m)^2; printf "%.3f", sqrt(v/NR) }'; }
# coefficient of variation (%) — the number that says whether a median is meaningful
cv_pct() { awk '{x[NR]=$1; s+=$1} END { if (NR<2 || s==0) { print "0.0"; exit } m=s/NR; for (i=1;i<=NR;i++) v+=(x[i]-m)^2; printf "%.1f", 100*sqrt(v/NR)/m }'; }

# ─────────────────────────────────────────────────────────────────────────────
# Environment capture — "record what you cannot control" (CI spec §6.4 rule 8)
# ─────────────────────────────────────────────────────────────────────────────
capture_environment() {
  local out="$1"
  {
    echo "TaskFlow benchmark environment"
    echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "── host ──────────────────────────────────────────────"
    echo "hostname:        $(hostname 2>/dev/null || echo '?')"
    echo "kernel:          $(uname -srm 2>/dev/null || echo '?')"
    echo "os:              $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") || uname -s )"
    echo "cpu model:       $(awk -F: '/model name/ {gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
    echo "cpu cores:       $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
    echo "memory total:    $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?')"
    echo "governor:        $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a')"
    echo "virtualisation:  $(systemd-detect-virt 2>/dev/null || echo '?')"
    echo
    echo "── load at capture time ──────────────────────────────"
    echo "loadavg:         $(cat /proc/loadavg 2>/dev/null || uptime)"
    # Rule 8: "whether the host looked idle". A benchmark started on a busy host
    # is not comparable with one started on an idle host, and the only honest
    # thing to do is record it and let the reader discount the run.
    local la1 cores idle_verdict
    la1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
    cores="$(nproc 2>/dev/null || echo 1)"
    idle_verdict="$(awk -v l="${la1}" -v c="${cores}" 'BEGIN { r = l/c; if (r < 0.20) print "IDLE (load/core=" sprintf("%.2f", r) ")"; else if (r < 0.50) print "LIGHTLY LOADED (load/core=" sprintf("%.2f", r) ") — results are suspect"; else print "BUSY (load/core=" sprintf("%.2f", r) ") — DO NOT TRUST THESE RESULTS" }')"
    echo "host looked:     ${idle_verdict}"
    echo
    echo "── toolchain ─────────────────────────────────────────"
    echo "docker:          $(docker --version 2>/dev/null || echo 'not installed')"
    echo "compose:         $(docker compose version 2>/dev/null | head -1 || echo 'n/a')"
    echo "k6:              $(k6 version 2>/dev/null | head -1 || echo "via docker ${K6_IMAGE}")"
    echo "postgres:        $(psql_q 'SHOW server_version' 2>/dev/null | tr -d '[:space:]' || echo '?')"
    echo "valkey:          $(valkey_cli INFO server 2>/dev/null | tr -d '\r' | awk -F: '/^redis_version/ {print $2}' || echo 'n/a')"
    echo
    echo "── container limits (must be identical across impls) ─"
    local i c lim
    for i in "${IMPLS_ALL[@]}"; do
      c="$(impl_container "$i")"
      if container_running "${c}"; then
        lim="$(container_limits "${c}")"
        printf '%-12s NanoCpus=%s Memory=%s CpuQuota=%s CpuPeriod=%s\n' "$i" ${lim}
      else
        printf '%-12s (not running)\n' "$i"
      fi
    done
    echo
    echo "── notes ─────────────────────────────────────────────"
    echo "Load generator ran on the SAME host as the services unless you"
    echo "arranged otherwise. A saturated generator measures itself; see"
    echo "benchmarks/README.md, fair-comparison rule 5."
  } > "${out}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Fair-comparison rule 2: identical resource limits, verified not assumed
# ─────────────────────────────────────────────────────────────────────────────
# Returns 0 if every RUNNING implementation container has identical CPU and
# memory limits. Prints the offenders otherwise.
verify_identical_limits() {
  local -a impls=("$@")
  (( ${#impls[@]} )) || impls=("${IMPLS_ALL[@]}")
  have_docker || { warn "docker unavailable — cannot verify resource limits"; return 2; }

  local ref="" ref_impl="" mismatch=0 i c lim
  for i in "${impls[@]}"; do
    c="$(impl_container "$i")" || continue
    container_running "${c}" || continue
    lim="$(container_limits "${c}")"
    if [[ -z "${ref}" ]]; then ref="${lim}"; ref_impl="$i"; continue; fi
    if [[ "${lim}" != "${ref}" ]]; then
      fail "resource limits differ: ${ref_impl} [${ref}] vs ${i} [${lim}]"
      mismatch=1
    fi
  done

  if [[ -z "${ref}" ]]; then
    warn "no implementation containers running — nothing to verify"
    return 2
  fi
  if (( mismatch )); then
    step "Fields are: NanoCpus Memory CpuQuota CpuPeriod"
    step "docker-compose.yml sets 'deploy.resources.limits' on the x-api-common"
    step "anchor. Note that 'deploy:' is only honoured by 'docker compose up'"
    step "in Compose v2 — if you started a container by hand it will be"
    step "unlimited, and the comparison is void."
    return 1
  fi
  # Rule 2 also means "limits are actually SET". Unlimited containers all match
  # each other and are still not a fair test, because the host's spare capacity
  # varies between runs.
  local nanocpus mem; read -r nanocpus mem _ _ <<<"${ref}"
  if [[ "${nanocpus}" == "0" && "${mem}" == "0" ]]; then
    warn "containers have NO cpu/memory limits (NanoCpus=0 Memory=0)"
    step "All five match, but 'unlimited' is not a controlled condition."
    step "Bring the stack up with 'docker compose up -d' so deploy.resources applies."
    return 1
  fi
  ok "resource limits identical across running implementations [${ref}]"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Warm-up (fair-comparison rule 3)
# ─────────────────────────────────────────────────────────────────────────────
# JIT runtimes (C#, TypeScript) are materially slower cold; so are connection
# pools that have not opened their connections and query planners that have not
# seen the query. Warm-up traffic is generated and then DISCARDED — it is never
# merged into the reported histogram.
warmup() {
  local base="$1" seconds="${2:-60}" rate="${3:-100}"
  [[ "${seconds}" -le 0 ]] && { step "warm-up skipped"; return 0; }
  step "warm-up: ${seconds}s at ${rate} rps (discarded)"
  local tmpdir; tmpdir="$(mktemp -d)"
  mkdir -p "${REPO_ROOT}/benchmarks/results/.warmup"
  if RESULTS_DIR="benchmarks/results/.warmup" k6_run tests/load/read-heavy.js \
      -e "BASE_URL=${base}" \
      -e "RATE=${rate}" \
      -e "DURATION=${seconds}s" \
      -e "RESULTS_DIR=benchmarks/results/.warmup" \
      -e "RUN_LABEL=warmup" \
      -e "SETUP_TASKS=${SETUP_TASKS:-25}" \
      --no-usage-report --quiet >"${tmpdir}/warmup.log" 2>&1; then
    step "warm-up complete (results discarded)"
  else
    warn "warm-up run reported failures — see ${tmpdir}/warmup.log"
    tail -5 "${tmpdir}/warmup.log" >&2 || true
  fi
  rm -rf "${REPO_ROOT}/benchmarks/results/.warmup"
}

# ─────────────────────────────────────────────────────────────────────────────
# jq guard
# ─────────────────────────────────────────────────────────────────────────────
# Path to pass as SEED_MANIFEST, or "" if there is no manifest.
#
# The k6 side now FAILS LOUDLY when SEED_MANIFEST is set but unopenable — a
# silently-missing manifest used to make the suite register a throwaway user, so
# every run measured a different dataset and fair-comparison rule 4 was violated
# with no error anywhere. Here we simply do not set it when the file is absent,
# and say why.
seed_manifest_arg() {
  local m="${SEED_MANIFEST:-benchmarks/seed-manifest.json}"
  if [[ "${m}" == /* ]]; then
    [[ -f "${m}" ]] && { printf '%s' "${m}"; return 0; }
  elif [[ -f "${REPO_ROOT}/${m}" ]]; then
    printf '%s' "${m}"; return 0
  fi
  warn "no seed manifest at ${m} — the load suite will register a throwaway user"
  step "Runs will each use DIFFERENT data, so they are not comparable."
  step "Fix:  scripts/seed.sh --size large --truncate"
  printf ''
  return 0
}

require_jq() {
  require_cmd jq \
    "jq parses the k6 JSON summaries into the report tables." \
    "  Debian/Ubuntu: sudo apt install jq" \
    "  macOS:         brew install jq"
}

# ASCII bar chart: reads "label value" pairs on stdin, draws to WIDTH columns.
#   chart_ascii <width> <unit> [fixed_max]
#
# fixed_max is not optional decoration. Two charts drawn back-to-back for
# comparison MUST share a scale — auto-scaling each one independently makes a
# 13 ms bar and a 900 ms bar the same length, which turns a comparison chart
# into a lie. Callers that draw a pair should compute the max across both and
# pass it to each.
chart_ascii() {
  local width="${1:-48}" unit="${2:-ms}" fixed_max="${3:-}"
  awk -v w="${width}" -v unit="${unit}" -v fixedmax="${fixed_max}" '
    { lab[NR]=$1; val[NR]=$2+0; if ($2+0 > mx) mx=$2+0 }
    END {
      if (NR==0) { print "  (no data)"; exit }
      if (fixedmax != "" && fixedmax+0 > 0) mx = fixedmax+0
      if (mx <= 0) mx = 1
      for (i=1; i<=NR; i++) {
        n = int(val[i]/mx*w + 0.5); if (n<1 && val[i]>0) n=1
        # Build the bar and pad with SPACES by character count. printf "%-*s"
        # pads by bytes, and "█" is three bytes in UTF-8 — using it here would
        # left-shift every long bar and quietly ruin the alignment.
        bar = ""
        for (j=0; j<n; j++) bar = bar "█"
        for (j=n; j<w; j++) bar = bar " "
        printf "  %-8s %s %8.1f%s\n", lab[i], bar, val[i], unit
      }
    }'
}

# Strip trailing zeros from a decimal: median() emits "400.000" for an even
# sample count, and "400.000 rps" reads like false precision in a report.
trim_zeros() {
  local v="$1"
  # Deliberately not using bash's +(0) extglob: extglob is off by default and
  # `shopt -s extglob` inside a sourced library changes the caller's shell.
  [[ "${v}" =~ ^-?[0-9]+\.[0-9]+$ ]] || { printf '%s' "${v}"; return; }
  while [[ "${v}" == *0 ]]; do v="${v%0}"; done
  printf '%s' "${v%.}"
}

# ─────────────────────────────────────────────────────────────────────────────
# The rest of the stack, by name
# ─────────────────────────────────────────────────────────────────────────────
#
# status.sh, dev-up.sh and chaos.sh all need to answer "is X up?" for the same
# set of services. Keeping the name → container → probe mapping in one place
# means adding a service to docker-compose does not require editing three
# scripts and forgetting the fourth.
# redpanda is NOT in this list: since Phase 6 moved to Valkey Streams it sits
# behind the `kafka` compose profile (infrastructure spec §4.9) and does not
# start by default, so reporting it as "down" every time would be noise. The
# name → container → probe mappings below keep working for it, so
# `status.sh` and `chaos.sh` still handle it once you bring the profile up.
export INFRA_SERVICES=(postgres valkey seaweedfs)
export OBS_SERVICES=(collector prometheus loki tempo grafana pyroscope)

# service key -> container name
service_container() {
  case "$1" in
    postgres)   echo "${PG_CONTAINER}" ;;
    valkey)     echo "${VALKEY_CONTAINER}" ;;
    redpanda)   echo taskflow-redpanda ;;
    seaweedfs)  echo taskflow-s3 ;;
    collector)  echo taskflow-otelcol ;;
    prometheus) echo taskflow-prometheus ;;
    loki)       echo taskflow-loki ;;
    tempo)      echo taskflow-tempo ;;
    grafana)    echo taskflow-grafana ;;
    pyroscope)  echo taskflow-pyroscope ;;
    *) return 1 ;;
  esac
}

# service key -> compose service name (differs from the container name)
service_compose_name() {
  case "$1" in
    postgres|valkey|redpanda|seaweedfs|prometheus|loki|tempo|grafana|pyroscope) echo "$1" ;;
    collector) echo otel-collector ;;
    *) return 1 ;;
  esac
}

# service key -> an HTTP URL that answers 200 when the service is usable, or ""
# when the only sensible probe is not HTTP (postgres, valkey).
service_probe_url() {
  case "$1" in
    redpanda)   echo "http://localhost:9644/v1/status/ready" ;;
    seaweedfs)  echo "http://localhost:9333/cluster/status" ;;
    collector)  echo "http://localhost:13133" ;;
    prometheus) echo "http://localhost:9090/-/healthy" ;;
    loki)       echo "http://localhost:3100/ready" ;;
    tempo)      echo "http://localhost:3200/ready" ;;
    grafana)    echo "http://localhost:3000/api/health" ;;
    pyroscope)  echo "http://localhost:4040/ready" ;;
    *) echo "" ;;
  esac
}

# Every port the stack publishes, as "port service" pairs. dev-up.sh refuses to
# start when one is taken, because "port is already allocated" from compose
# names the container it failed to create and not the thing already on the port.
core_ports() {
  cat <<'EOF'
5432 postgres
8001 go-api
8002 rust-api
8003 python-api
8004 csharp-api
8005 typescript-api
EOF
}
infra_ports() {
  cat <<'EOF'
6379 valkey
8081 redpanda-schema-registry
8090 redpanda-console
8333 seaweedfs-s3
9092 redpanda-kafka
9333 seaweedfs-master
9644 redpanda-admin
EOF
}
obs_ports() {
  cat <<'EOF'
3000 grafana
3100 loki
3200 tempo
4040 pyroscope
4317 otel-collector-grpc
4318 otel-collector-http
8890 otel-collector-metrics
9090 prometheus
13133 otel-collector-health
55679 otel-collector-zpages
EOF
}

# The URL list that every "the stack is up" message ends with.
print_urls() {
  local include_obs="${1:-auto}"
  printf '\n  %sURLs%s\n' "${C_BOLD}" "${C_RESET}" >&2
  local i port
  for i in "${IMPLS_ALL[@]}"; do
    port="$(impl_port "$i")"
    printf '    %-14s http://localhost:%s/api/v1\n' "${i}" "${port}" >&2
  done
  printf '    %-14s http://localhost:9333            (SeaweedFS master)\n' "s3" >&2
  printf '    %-14s http://localhost:8090            (Redpanda console)\n' "kafka" >&2
  printf '    %-14s postgresql://postgres:password@localhost:5432/taskflow_dev\n' "postgres" >&2
  if [[ "${include_obs}" == "yes" ]] || { [[ "${include_obs}" == "auto" ]] && container_running taskflow-grafana; }; then
    printf '    %-14s http://localhost:3000            (anonymous admin)\n' "grafana" >&2
    printf '    %-14s http://localhost:9090\n' "prometheus" >&2
    printf '    %-14s http://localhost:4040\n' "pyroscope" >&2
    printf '    %-14s http://localhost:3200/ready\n' "tempo" >&2
  else
    printf '    %sobservability stack is not running — make up-full%s\n' "${C_DIM}" "${C_RESET}" >&2
  fi
  printf '\n' >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Container introspection
# ─────────────────────────────────────────────────────────────────────────────
# Exists at all, running or not. The distinction matters for the observability
# stack: "never started" and "crashed" deserve different words.
container_exists() {
  [[ -n "$(docker ps -aq -f "name=^/${1}$" 2>/dev/null)" ]]
}

# healthy | unhealthy | starting | none | (empty if the container is unknown)
container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$1" 2>/dev/null || true
}

# Host PID of a container's main process. Used to read /proc/<pid>/fd, which
# works even for distroless images that have no shell to exec into.
container_pid() {
  docker inspect --format '{{.State.Pid}}' "$1" 2>/dev/null || true
}

# Open file descriptors held by a container's main process, or "" if unknown.
container_open_fds() {
  local name="$1" pid
  pid="$(container_pid "${name}")"
  if [[ -n "${pid}" && "${pid}" != "0" && -r "/proc/${pid}/fd" ]]; then
    find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
    return 0
  fi
  # Fallback for a rootless / remote daemon where /proc is not the same kernel.
  docker exec "${name}" sh -c 'ls /proc/1/fd | wc -l' 2>/dev/null | tr -d ' ' || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Images — pull once, say so, and let the caller SKIP rather than fail
# ─────────────────────────────────────────────────────────────────────────────
image_present() { docker image inspect "$1" >/dev/null 2>&1; }

# ensure_image <ref> — 0 if the image is now local, 1 if it could not be had.
# Never fatal: a linter whose image will not pull is a SKIP with a reason, not
# a failed build. An air-gapped machine should still be able to run the checks
# it can run.
ensure_image() {
  local ref="$1"
  image_present "${ref}" && return 0
  step "pulling ${ref}"
  docker pull --quiet "${ref}" >/dev/null 2>&1 && return 0
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Ports
# ─────────────────────────────────────────────────────────────────────────────
# "who is on port N?" — returns "<comm> (pid <n>)", "docker: <container>", or "".
# Tries ss, then lsof, then a bare connect. The bare-connect fallback cannot
# name the process, but "something is listening" still beats a compose error.
port_listener() {
  local port="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -Hltnp "sport = :${port}" 2>/dev/null | head -1)"
    if [[ -n "${out}" ]]; then
      local proc
      proc="$(sed -n 's/.*users:((\"\([^"]*\)\",pid=\([0-9]*\).*/\1 (pid \2)/p' <<<"${out}")"
      [[ -z "${proc}" ]] && proc="an unnamed process (run as root to see it)"
      printf '%s' "${proc}"
      return 0
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -Fcp 2>/dev/null | tr '\n' ' ')"
    if [[ -n "${out}" ]]; then
      printf '%s' "$(awk '{for(i=1;i<=NF;i++){if($i ~ /^c/) c=substr($i,2); if($i ~ /^p/) p=substr($i,2)}} END{printf "%s (pid %s)", c, p}' <<<"${out}")"
      return 0
    fi
  fi
  # Last resort: can we connect? bash's /dev/tcp needs no external command.
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    exec 3<&- 2>/dev/null || true
    printf 'an unidentified listener'
    return 0
  fi
  return 1
}

port_free() { ! port_listener "$1" >/dev/null 2>&1; }

# If the listener is one of our own containers, say which — "port 5432 is taken
# by taskflow-db" means "the stack is already up", not "you have a conflict".
port_container() {
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
    | awk -v p=":${1}->" 'index($0, p) { print $1; exit }'
}

# ─────────────────────────────────────────────────────────────────────────────
# .env
# ─────────────────────────────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

# Value of KEY from .env without sourcing it — sourcing an untrusted .env runs
# whatever is in it, and a stray backtick in a password should not execute.
env_file_value() {
  local key="$1" file="${2:-${ENV_FILE}}"
  [[ -f "${file}" ]] || return 1
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "${file}" \
    | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

random_secret() {
  openssl rand -hex 32 2>/dev/null && return 0
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Create .env if it is missing. Mirrors `make setup` so `dev-up.sh` on a fresh
# clone does not fail with a wall of "variable is not set" warnings.
ensure_env_file() {
  [[ -f "${ENV_FILE}" ]] && return 0
  if [[ -f "${REPO_ROOT}/.env.example" ]]; then
    cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
    step "created .env from .env.example"
  else
    cat > "${ENV_FILE}" <<EOF
# Generated by scripts/lib/common.sh because neither .env nor .env.example
# existed. Every other setting has a working default in docker-compose.yml.
JWT_SECRET=$(random_secret)
LOG_LEVEL=info
CACHE_ENABLED=true
RATE_LIMIT_ENABLED=true
EOF
    step "created .env with a random JWT_SECRET"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary tables
# ─────────────────────────────────────────────────────────────────────────────
#
# validate.sh, lint.sh, conformance.sh and chaos.sh all end with "here is what
# passed and what did not". One implementation means one alignment bug to fix
# and one set of words for the states.
#
# States: PASS FAIL SKIP WARN UP DOWN — anything else prints uncoloured.
SUMMARY_LABEL=(); SUMMARY_STATE=(); SUMMARY_NOTE=()

summary_reset() { SUMMARY_LABEL=(); SUMMARY_STATE=(); SUMMARY_NOTE=(); }
summary_add()   { SUMMARY_LABEL+=("$1"); SUMMARY_STATE+=("$2"); SUMMARY_NOTE+=("${3:-}"); }
summary_size()  { printf '%d' "${#SUMMARY_LABEL[@]}"; }

summary_count() {
  local want="$1" n=0 s
  (( ${#SUMMARY_STATE[@]} )) || { printf '0'; return; }
  for s in "${SUMMARY_STATE[@]}"; do [[ "${s}" == "${want}" ]] && n=$(( n + 1 )); done
  printf '%d' "${n}"
}

state_colour() {
  case "$1" in
    PASS|UP|OK|READY) printf '%s' "${C_GREEN}" ;;
    FAIL|DOWN)        printf '%s' "${C_RED}" ;;
    WARN|PARTIAL)     printf '%s' "${C_YELLOW}" ;;
    SKIP|"n/a"|"—")   printf '%s' "${C_DIM}" ;;
    *)                printf '%s' "${C_RESET}" ;;
  esac
}

# Display width in characters, not bytes. printf pads by BYTES in the C locale,
# so a column containing "—" (three bytes, one glyph) shifts everything to its
# right by two — the same trap chart_ascii() documents for "█".
strwidth() {
  LC_ALL=C awk '{ gsub(/[\200-\277]/, ""); print length($0) }' <<<"$1"
}

# Pad manually, colour outside the padding. Colouring first would make printf
# count the escape sequence toward the field width and every row would drift a
# little further right than the one above it.
cell() {
  local text="$1" width="$2" colour="${3:-}" w pad
  w="$(strwidth "${text}")"
  pad=$(( width - w )); (( pad < 0 )) && pad=0
  printf '%s%s%s%*s' "${colour}" "${text}" "${C_RESET}" "${pad}" ""
}

summary_print() {
  # Floor of 5 so the "check" header itself never overflows the column and
  # shifts the two to its right. Widths come from strwidth, not ${#}, because
  # labels routinely contain "·" and "—".
  local title="${1:-summary}" i w=5 lw
  (( ${#SUMMARY_LABEL[@]} )) || { printf '  (nothing to report)\n' >&2; return 0; }
  for i in "${!SUMMARY_LABEL[@]}"; do
    lw="$(strwidth "${SUMMARY_LABEL[$i]}")"
    (( lw > w )) && w="${lw}"
  done
  printf '\n  %s%s%s\n' "${C_BOLD}" "${title}" "${C_RESET}" >&2
  printf '  %s  %s %s%s%s\n' \
    "$(cell "check" "${w}" "${C_DIM}")" "$(cell "result" 7 "${C_DIM}")" \
    "${C_DIM}" "notes" "${C_RESET}" >&2
  printf '  %s\n' "$(printf '─%.0s' $(seq 1 $(( w + 40 ))))" >&2
  for i in "${!SUMMARY_LABEL[@]}"; do
    printf '  %s  %s %s\n' \
      "$(cell "${SUMMARY_LABEL[$i]}" "${w}")" \
      "$(cell "${SUMMARY_STATE[$i]}" 7 "$(state_colour "${SUMMARY_STATE[$i]}")")" \
      "${SUMMARY_NOTE[$i]}" >&2
  done
  printf '\n' >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Durations and trend maths
# ─────────────────────────────────────────────────────────────────────────────
# "1h", "90m", "1h30m", "45s" or a bare number of seconds → seconds.
parse_duration_seconds() {
  local d="$1"
  [[ "${d}" =~ ^[0-9]+$ ]] && { printf '%s' "${d}"; return 0; }
  [[ "${d}" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ && -n "${d}" ]] || return 1
  local h="${BASH_REMATCH[1]%h}" m="${BASH_REMATCH[2]%m}" s="${BASH_REMATCH[3]%s}"
  printf '%d' $(( ${h:-0} * 3600 + ${m:-0} * 60 + ${s:-0} ))
}

# Least-squares fit over "x y" pairs on stdin → "slope intercept r2 n".
#
# Used by soak.sh for leak detection. The slope alone is not enough: a sawtooth
# from garbage collection has a slope too, but a terrible fit. Requiring R²
# alongside the slope is what separates "the floor is climbing" (a leak) from
# "it goes up and down" (a healthy heap).
linreg() {
  awk '
    { n++; sx+=$1; sy+=$2; sxx+=$1*$1; sxy+=$1*$2; syy+=$2*$2 }
    END {
      if (n < 3) { print "0 0 0 " n+0; exit }
      d = n*sxx - sx*sx
      if (d == 0)  { print "0 0 0 " n+0; exit }
      slope = (n*sxy - sx*sy) / d
      icept = (sy - slope*sx) / n
      den = d * (n*syy - sy*sy)
      r2 = (den > 0) ? ((n*sxy - sx*sy)^2) / den : 0
      printf "%.6g %.6g %.4f %d\n", slope, icept, r2, n
    }'
}

# ── which languages is this project currently using? ─────────────────────────
# Single source of truth: COMPOSE_PROFILES in .env, written by
# scripts/use-languages.sh. The progress-reporting tools (check-phase, progress,
# status) narrow to this set so a one-language project never shows four
# permanently-empty columns. benchmark.sh and profile.sh deliberately do NOT
# call this — they resolve `--impl all` to IMPLS_ALL, because a benchmark exists
# to compare and silently dropping four of five would be the wrong default.
#
# Falls back to all five when .env is missing or the line is absent, which is
# the right default for a fresh clone.
configured_languages() {
  local root env_file value
  root="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  env_file="${root}/.env"
  if [[ -f "$env_file" ]]; then
    value="$(grep -E '^COMPOSE_PROFILES=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    # Strip profiles that are not languages (e.g. the optional `kafka` one).
    if [[ -n "$value" ]]; then
      local out=() l
      IFS=',' read -r -a __cfg <<< "${value// /}"
      for l in "${__cfg[@]}"; do
        case "$l" in go|rust|python|csharp|typescript) out+=("$l") ;; esac
      done
      if (( ${#out[@]} )); then printf '%s\n' "${out[@]}"; return 0; fi
    fi
  fi
  printf '%s\n' go rust python csharp typescript
}

# Comma-joined form, for passing to pytest --impl and friends.
# read-loop rather than `mapfile`: this helper is called from scripts that are
# otherwise happy on bash 3.2, and mapfile would drag the whole floor up.
configured_languages_csv() {
  local langs=() l
  while IFS= read -r l; do [[ -n "$l" ]] && langs+=("$l"); done < <(configured_languages)
  local IFS=,; echo "${langs[*]}"
}
