#!/usr/bin/env bash
#
# profile-diff.sh — which frames does the cache make disappear?
#
# Captures two profiles of the same service under the same load, one with
# CACHE_ENABLED=false and one with CACHE_ENABLED=true, then reports which stack
# frames lost the most samples.
#
# This is the bridge between the benchmark story and the profiling story.
# bench-cache.sh tells you the database served 87% fewer queries; this tells you
# WHICH CODE stopped running to make that happen — the driver's row parsing, the
# connection acquire, the query builder, the ORM hydration. Seeing those frames
# vanish is what turns "caching is faster" from a slogan into something you
# understand mechanically.
#
# It also catches the disappointing case, which is worth just as much: if the
# frames that vanish are 3% of the graph and the widest block is still
# `epoll_wait`, then the service was never CPU-bound on the database and the
# cache bought you latency, not capacity.
#
#   scripts/profile-diff.sh --impl go
#   scripts/profile-diff.sh --impl python --duration 45
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

IMPL="go"
DURATION=30
LOAD_RATE=300
OUT_BASE="profiles"
TOP_N=25
SEED_SIZE="large"
RESEED=0

usage() {
  cat <<'EOF'
profile-diff.sh — capture profiles with the cache on and off, diff the frames

USAGE
  scripts/profile-diff.sh [--impl <lang>] [--duration N]

OPTIONS
  --impl <lang>     go | rust | python | csharp | typescript   (default go)
  --duration N      profile duration per configuration, seconds (default 30)
  --rate N          arrival rate during capture                 (default 300)
  --top N           how many changed frames to list             (default 25)
  --reseed          re-seed the database before each capture
  --seed-size <s>   small | large | huge                        (default large)
  --out DIR         output base directory                       (default profiles)
  -h, --help

OUTPUT  (profiles/<ts>/)
  cache-off/<lang>/   profile captured with CACHE_ENABLED=false
  cache-on/<lang>/    profile captured with CACHE_ENABLED=true
  diff.md             the frames that disappeared, ranked

HOW THE DIFF IS COMPUTED
  Where both captures produced a pprof profile, `go tool pprof -base` does it
  properly (it understands the format and subtracts sample-by-sample).
  Otherwise the script falls back to folded stacks: aggregate samples per frame,
  normalise each side to a percentage of its own total, and compare shares. The
  percentage normalisation matters — with the cache on the process does less
  work overall, so almost every ABSOLUTE count drops and a raw subtraction would
  say everything improved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)      IMPL="${2:?}"; shift 2 ;;
    --duration)  DURATION="${2:?}"; shift 2 ;;
    --rate)      LOAD_RATE="${2:?}"; shift 2 ;;
    --top)       TOP_N="${2:?}"; shift 2 ;;
    --reseed)    RESEED=1; shift ;;
    --seed-size) SEED_SIZE="${2:?}"; shift 2 ;;
    --out)       OUT_BASE="${2:?}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

is_impl "${IMPL}" || die "unknown implementation '${IMPL}' (expected: ${IMPLS_ALL[*]})"
require_docker

TS="$(timestamp)"
OUT_DIR="${REPO_ROOT}/${OUT_BASE}/${TS}"
mkdir -p "${OUT_DIR}"
BASE="$(impl_base_url "${IMPL}")"
SVC="$(impl_service "${IMPL}")"

section "profile diff — ${IMPL}"
info "duration  ${DURATION}s per configuration"
info "output    ${OUT_BASE}/${TS}"

if [[ "$(http_status "${BASE}/api/v1/health/live" 3)" != "200" ]]; then
  compose up -d "${SVC}" >/dev/null 2>&1 || true
  wait_for_health "${BASE}" 120 || die "${IMPL} is not running at ${BASE}"
fi
assert_implemented "${BASE}" "${IMPL}"

capture() {
  # Two statements, not one. In `local a="$1" b="x-$a"`, bash expands $a from
  # the OUTER scope — the local a does not exist yet — so a single line here
  # produced dir="cache-" for both captures, both of them wrote to the same
  # directory, and the diff below compared a profile with itself.
  local cache="$1"
  local dir="cache-${cache}"
  section "CACHE_ENABLED=${cache}"

  # PROFILING_ENABLED=true is what makes the pprof / inspector endpoints exist
  # at all. Both captures get it, so its 1-3% overhead is in both columns and
  # cancels out of the comparison.
  step "recreating ${SVC} with CACHE_ENABLED=${cache} PROFILING_ENABLED=true"
  ( cd "${REPO_ROOT}" && CACHE_ENABLED="${cache}" PROFILING_ENABLED=true RATE_LIMIT_ENABLED=false \
      docker compose up -d --force-recreate --no-deps "${SVC}" ) >/dev/null 2>&1 \
    || die "could not recreate ${SVC}"
  wait_for_health "${BASE}" 120 || die "${IMPL} not ready after restart"

  if (( RESEED )); then
    step "re-seeding (${SEED_SIZE})"
    bash "${SCRIPT_DIR}/seed.sh" --size "${SEED_SIZE}" --truncate --quiet >/dev/null 2>&1 || true
  fi

  # Warm up so the profile describes steady-state work rather than cold caches,
  # cold JITs and cold connection pools. With the cache ON this also populates
  # it — profiling a cold cache would show you cache MISSES, which is the
  # opposite of the point.
  warmup "${BASE}" 30 "${LOAD_RATE}"

  # profile.sh writes to <out>/<ts>/<impl>, so passing --out <base>/<TS> and
  # --ts cache-<on|off> lands the capture at profiles/<TS>/cache-<x>/<impl>.
  bash "${SCRIPT_DIR}/profile.sh" --impl "${IMPL}" --duration "${DURATION}" \
    --rate "${LOAD_RATE}" --out "${OUT_BASE}/${TS}" --ts "${dir}" \
    >"${OUT_DIR}/${dir}-capture.log" 2>&1 \
    || warn "profile.sh reported problems for cache=${cache} (see ${dir}-capture.log)"
}

capture false
capture true

OFF_DIR="${OUT_DIR}/cache-false/${IMPL}"
ON_DIR="${OUT_DIR}/cache-true/${IMPL}"
DIFF_MD="${OUT_DIR}/diff.md"

# ─────────────────────────────────────────────────────────────────────────────
# Folded-stack diff (language-agnostic fallback)
# ─────────────────────────────────────────────────────────────────────────────
# Reads two "stack;frames count" files. Attributes each sample to every frame in
# its stack (so a frame's share is its CUMULATIVE cost, matching how you read a
# flamegraph), normalises to a percentage of each side's total, and reports the
# largest drops.
fold_diff() {
  local off="$1" on="$2" top="$3"
  awk -v top="${top}" '
    function accum(file, arr,   line, nf, parts, i, cnt, stack, seen) {
      while ((getline line < file) > 0) {
        nf = split(line, w, " ")
        if (nf < 2) continue
        cnt = w[nf] + 0
        stack = w[1]
        for (i = 2; i < nf; i++) stack = stack " " w[i]
        n = split(stack, parts, ";")
        delete seen
        for (i = 1; i <= n; i++) {
          f = parts[i]
          gsub(/^[ \t]+|[ \t]+$/, "", f)
          if (f == "" || (f in seen)) continue   # recursion: count a frame once
          seen[f] = 1
          arr[f] += cnt
          total += cnt
        }
      }
      close(file)
      return total
    }
    BEGIN {
      total = 0; toff = accum(ARGV[1], A); total = 0; ton = accum(ARGV[2], B)
      ARGV[1] = ""; ARGV[2] = ""   # already consumed via getline; do not re-read
      if (toff == 0 || ton == 0) { print "  (no folded stacks to diff)"; exit }
      for (f in A) all[f] = 1
      for (f in B) all[f] = 1
      n = 0
      for (f in all) {
        pa = 100 * A[f] / toff
        pb = 100 * B[f] / ton
        d = pa - pb
        if (pa < 0.3 && pb < 0.3) continue      # ignore trivia
        n++; frames[n] = f; da[n] = pa; db[n] = pb; dd[n] = d
      }
      for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++)
        if (dd[j] > dd[i]) { t=dd[i];dd[i]=dd[j];dd[j]=t; t=da[i];da[i]=da[j];da[j]=t;
                             t=db[i];db[i]=db[j];db[j]=t; t=frames[i];frames[i]=frames[j];frames[j]=t }
      printf "| frame | cache OFF | cache ON | change |\n|---|---|---|---|\n"
      shown = 0
      for (i = 1; i <= n && shown < top; i++) {
        if (dd[i] <= 0.2) break
        printf "| `%s` | %.1f%% | %.1f%% | **-%.1f pp** |\n", frames[i], da[i], db[i], dd[i]
        shown++
      }
      if (shown == 0) printf "| *(no frame lost more than 0.2 percentage points)* | | | |\n"
      printf "\nFRAMES THAT GREW\n\n"
      printf "| frame | cache OFF | cache ON | change |\n|---|---|---|---|\n"
      shown = 0
      for (i = n; i >= 1 && shown < 10; i--) {
        if (dd[i] >= -0.2) break
        printf "| `%s` | %.1f%% | %.1f%% | **+%.1f pp** |\n", frames[i], da[i], db[i], -dd[i]
        shown++
      }
      if (shown == 0) printf "| *(nothing grew by more than 0.2 percentage points)* | | | |\n"
    }' "${off}" "${on}"
}

section "diff"
{
  echo "# Profile diff — ${IMPL}, cache off vs cache on"
  echo
  echo "- **generated** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **duration** ${DURATION}s per configuration, ${LOAD_RATE} rps read-heavy"
  echo "- **captures** \`cache-false/\` and \`cache-true/\`"
  echo
  echo "Both captures ran with \`PROFILING_ENABLED=true\`, so the profiler's 1-3%"
  echo "overhead is present in both columns and cancels out. Both were warmed up for"
  echo "30 s first — profiling a cold cache would show you cache *misses*."
  echo

  DID_DIFF=0

  # Preferred: pprof's own -base subtraction.
  if [[ -f "${OFF_DIR}/cpu.pb.gz" && -f "${ON_DIR}/cpu.pb.gz" ]] && command -v go >/dev/null 2>&1; then
    echo "## What the cache removed (\`go tool pprof -base\`)"
    echo
    echo "Negative entries are work that disappeared when the cache was turned on."
    echo
    echo '```'
    go tool pprof -base "${ON_DIR}/cpu.pb.gz" -top -cum -nodecount="${TOP_N}" \
      "${OFF_DIR}/cpu.pb.gz" 2>/dev/null || echo "(pprof -base failed)"
    echo '```'
    echo
    echo "Read the \`cum\` column: it is the time in a function *and everything it*"
    echo "*called*, which is what a flamegraph's width shows. Expect the database"
    echo "driver's query, row-scan and connection-acquire paths near the top."
    echo
    if go tool pprof -base "${ON_DIR}/cpu.pb.gz" -svg \
         -output "${OUT_DIR}/diff.svg" "${OFF_DIR}/cpu.pb.gz" >/dev/null 2>&1; then
      echo "A differential call graph is at \`diff.svg\` (needs graphviz)."
      echo
      ok "diff.svg written"
    fi
    DID_DIFF=1
  fi

  # Fallback: folded stacks.
  if [[ -f "${OFF_DIR}/cpu.folded" && -f "${ON_DIR}/cpu.folded" ]]; then
    echo "## Frames that shrank (folded-stack diff)"
    echo
    echo "Each frame's share of its own capture, so the comparison is not distorted"
    echo "by the cached run simply doing less work overall. \`pp\` = percentage points."
    echo
    fold_diff "${OFF_DIR}/cpu.folded" "${ON_DIR}/cpu.folded" "${TOP_N}"
    echo
    DID_DIFF=1
  fi

  if (( DID_DIFF == 0 )); then
    echo "## No diff could be computed"
    echo
    echo "Neither capture produced a profile in a comparable format. See:"
    echo
    echo "- \`cache-false/${IMPL}/notes.md\`"
    echo "- \`cache-true/${IMPL}/notes.md\`"
    echo
    echo "Each explains exactly what is missing and the change needed to enable it."
    echo
    echo "You can still compare the two flamegraphs by eye if the SVGs exist —"
    echo "\`profiles/${TS}/cache-false/${IMPL}/cpu.svg\` and \`.../cache-true/${IMPL}/cpu.svg\`. Look for"
    echo "database-driver frames that are wide in the first and absent in the second."
    echo
  fi

  echo "## How to read this"
  echo
  echo "**The frames that disappear are the work the cache removed.** In a"
  echo "cache-aside service they should be, roughly in order:"
  echo
  echo "1. **the database driver** — query execution, row scanning, result-set"
  echo "   decoding. This is usually the largest single block."
  echo "2. **connection-pool acquire** — often invisible in the *benchmark* because"
  echo "   it shows up as waiting rather than CPU, but very visible here if the pool"
  echo "   was saturated."
  echo "3. **object mapping** — turning rows into structs/dicts/objects. In Python"
  echo "   and TypeScript this is frequently larger than the query itself."
  echo "4. **serialisation** — only partly, and only if responses are cached"
  echo "   pre-serialised. Caching the *object* and re-serialising on every hit"
  echo "   leaves this cost exactly where it was, and that is a common and"
  echo "   easily-missed miss."
  echo
  echo "**What should APPEAR instead:** the Redis/Valkey client — connection"
  echo "handling, RESP protocol parsing, and deserialising the cached value."
  echo "If that new work is close in size to the work it replaced, the cache is"
  echo "buying you very little on CPU and its value is elsewhere (database load,"
  echo "tail latency under queueing)."
  echo
  echo "**If almost nothing changed**, the honest conclusion is that this service"
  echo "was not CPU-bound on the database. Cross-check the numbers in"
  echo "\`benchmarks/results/*/cache-ab.md\`: if the query count dropped sharply but"
  echo "the CPU profile barely moved, then the time was being spent WAITING on"
  echo "Postgres, not computing — and the cache's benefit is capacity and tail"
  echo "latency, not CPU. That is still a win; it is just a different one, and"
  echo "saying which is which is the whole point of doing both measurements."
  echo
  echo "See \`profiles/${TS}/*/README.md\` for how to read a flamegraph."
} > "${DIFF_MD}"

# Copy the flamegraph reading guide next to the diff.
[[ -f "${OUT_DIR}/cache-false/README.md" ]] && cp "${OUT_DIR}/cache-false/README.md" "${OUT_DIR}/README.md" 2>/dev/null || true
# (profile.sh writes the flamegraph-reading guide into each capture directory.)

ok "diff → ${OUT_BASE}/${TS}/diff.md"
step "captures: ${OUT_BASE}/${TS}/cache-false/${IMPL}/  and  ${OUT_BASE}/${TS}/cache-true/${IMPL}/"

warn "the service is still running with CACHE_ENABLED=true PROFILING_ENABLED=true"
step "restore normal settings:  docker compose up -d --force-recreate ${SVC}"
