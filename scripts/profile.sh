#!/usr/bin/env bash
#
# profile.sh — capture CPU and heap profiles under load, in all five languages.
#
# A benchmark tells you a service is slow. A profile tells you WHERE. The two
# are only useful together, which is why this script generates the load itself
# rather than expecting you to run k6 in another terminal: an idle process
# profiles as "epoll_wait, 99%", which is true and useless.
#
# Profiling is deliberately gated behind PROFILING_ENABLED=true (see
# docker-compose.yml). Overhead is 1-3% CPU — real but acceptable — and leaving
# it on everywhere just adds noise to the benchmark numbers.
#
#   scripts/profile.sh --impl go
#   scripts/profile.sh --impl all --duration 60
#   scripts/profile.sh --impl python --no-load     # profile whatever is happening now
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

IMPL_ARG="all"
DURATION=30
LOAD_RATE=300
NO_LOAD=0
HEAP=1
OUT_BASE="profiles"
PROFILE_TS=""

usage() {
  cat <<'EOF'
profile.sh — per-language CPU and heap profiles captured under load

USAGE
  scripts/profile.sh [--impl <lang|all>] [--duration N] [options]

OPTIONS
  --impl <lang|all>   go | rust | python | csharp | typescript | all  (default all)
  --duration N        profile duration in seconds                    (default 30)
  --rate N            arrival rate of the load generated during capture (default 300)
  --no-load           do not generate load; profile the process as-is
  --no-heap           CPU profile only
  --out DIR           output base directory                          (default profiles)
  --ts TAG            use this timestamp/tag instead of generating one
                      (profile-diff.sh uses it to group two captures)
  -h, --help

OUTPUT
  profiles/<ts>/<lang>/cpu.*      raw profile in the language's native format
  profiles/<ts>/<lang>/cpu.svg    flamegraph, where the tooling can produce one
  profiles/<ts>/<lang>/heap.*     heap/allocation profile
  profiles/<ts>/<lang>/notes.md   what was captured, what was missing, how to fix
  profiles/<ts>/README.md         how to read a flamegraph, per-language guide

TOOLING (each is optional; a missing one is reported, not fatal)
  go          net/http/pprof endpoint + `go tool pprof`
  rust        pprof-rs endpoint, else `perf record` + a flamegraph tool
  python      `py-spy record` attached to the container's PID
  csharp      `dotnet-trace collect`
  typescript  `node --cpu-prof`, else the inspector protocol
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)     IMPL_ARG="${2:?}"; shift 2 ;;
    --duration) DURATION="${2:?}"; shift 2 ;;
    --rate)     LOAD_RATE="${2:?}"; shift 2 ;;
    --no-load)  NO_LOAD=1; shift ;;
    --no-heap)  HEAP=0; shift ;;
    --out)      OUT_BASE="${2:?}"; shift 2 ;;
    --ts)       PROFILE_TS="${2:?}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

declare -a IMPLS=()
if [[ "${IMPL_ARG}" == "all" ]]; then IMPLS=("${IMPLS_ALL[@]}"); else
  IFS=',' read -r -a IMPLS <<< "${IMPL_ARG}"
  for i in "${IMPLS[@]}"; do is_impl "$i" || die "unknown implementation '$i'"; done
fi

PROFILE_TS="${PROFILE_TS:-$(timestamp)}"
OUT_DIR="${REPO_ROOT}/${OUT_BASE}/${PROFILE_TS}"
mkdir -p "${OUT_DIR}"

section "profiling"
info "impls     ${IMPLS[*]}"
info "duration  ${DURATION}s"
info "output    ${OUT_BASE}/${PROFILE_TS}"

# Port the service exposes its profiling endpoint on. Kept OFF the main port so
# /debug/pprof is never reachable from wherever the API is reachable from —
# a pprof endpoint on a public port is a denial-of-service primitive and a
# source-code leak.
pprof_port() {
  case "$1" in
    go)         echo "${GO_PPROF_PORT:-6060}" ;;
    rust)       echo "${RUST_PPROF_PORT:-6061}" ;;
    python)     echo "${PY_PPROF_PORT:-6062}" ;;
    csharp)     echo "${CS_PPROF_PORT:-6063}" ;;
    typescript) echo "${TS_INSPECT_PORT:-9229}" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Load generation, in the background, for the duration of the capture.
# ─────────────────────────────────────────────────────────────────────────────
LOAD_PID=""
start_load() {
  local base="$1" seconds="$2"
  (( NO_LOAD )) && { step "--no-load: profiling the process as it currently is"; return 0; }
  step "generating ${LOAD_RATE} rps of read-heavy traffic for the capture window"
  mkdir -p "${REPO_ROOT}/benchmarks/results/.profile-load"
  (
    k6_run tests/load/read-heavy.js \
      -e "BASE_URL=${base}" -e "RATE=${LOAD_RATE}" -e "DURATION=$(( seconds + 10 ))s" \
      -e "RESULTS_DIR=benchmarks/results/.profile-load" -e "RUN_LABEL=profile" \
      --no-usage-report --quiet >/dev/null 2>&1 || true
  ) &
  LOAD_PID=$!
  sleep 5   # let the load settle before sampling starts
}
stop_load() {
  [[ -n "${LOAD_PID}" ]] && { kill "${LOAD_PID}" >/dev/null 2>&1 || true; wait "${LOAD_PID}" 2>/dev/null || true; }
  LOAD_PID=""
  rm -rf "${REPO_ROOT}/benchmarks/results/.profile-load"
}
trap 'stop_load' EXIT INT TERM

# Host PID of a container's main process — what py-spy and perf attach to.
container_pid() {
  docker inspect --format '{{.State.Pid}}' "$1" 2>/dev/null || echo ""
}

endpoint_alive() {
  [[ "$(http_status "$1" 3)" =~ ^(200|405)$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Flamegraph rendering from folded ("collapsed") stacks.
# ─────────────────────────────────────────────────────────────────────────────
# Folded format is one line per stack: "a;b;c 123". It is the lingua franca of
# flamegraph tooling and the format profile-diff.sh diffs, so every language
# path here tries to end up with a .folded file even when it also produces a
# native one.
fold_to_svg() {
  local folded="$1" svg="$2"
  if command -v inferno-flamegraph >/dev/null 2>&1; then
    inferno-flamegraph < "${folded}" > "${svg}" 2>/dev/null && return 0
  fi
  if command -v flamegraph.pl >/dev/null 2>&1; then
    flamegraph.pl "${folded}" > "${svg}" 2>/dev/null && return 0
  fi
  if command -v stackcollapse-perl >/dev/null 2>&1; then :; fi
  return 1
}

note() { printf '%s\n' "$*" >> "${NOTES}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Go — net/http/pprof
# ─────────────────────────────────────────────────────────────────────────────
profile_go() {
  local dir="$1" base="$2" port; port="$(pprof_port go)"
  local url="http://localhost:${port}/debug/pprof"

  if ! endpoint_alive "${url}/"; then
    fail "go: no pprof endpoint on :${port}"
    note '## Go — pprof endpoint missing'
    note ''
    note 'Nothing was captured. The skeleton does not expose `net/http/pprof` yet.'
    note 'It is a two-line addition to `go/cmd/server/main.go`, guarded so it is'
    note 'only ever reachable on a separate port:'
    note ''
    note '```go'
    note 'import _ "net/http/pprof"   // registers handlers on http.DefaultServeMux'
    note ''
    note '// ...inside run(), after the main server is configured:'
    note 'if cfg.ProfilingEnabled {'
    note '    go func() {'
    note '        // DefaultServeMux, NOT the chi router: /debug/pprof must not be'
    note '        // reachable from wherever the API is reachable from. A pprof'
    note '        // endpoint on a public port leaks source paths and is a'
    note '        // denial-of-service primitive (profile?seconds=3600 pins a core).'
    note '        log.Info("pprof listening", slog.String("addr", ":6060"))'
    note '        _ = http.ListenAndServe("localhost:6060", nil)'
    note '    }()'
    note '}'
    note '```'
    note ''
    note 'Then publish the port for benchmark runs only:'
    note '```yaml'
    note '  go-api:'
    note '    ports: ["8001:8080", "6060:6060"]   # 6060 in the benchmark env ONLY'
    note '    environment:'
    note '      PROFILING_ENABLED: "true"'
    note '```'
    return 1
  fi

  step "go: CPU profile, ${DURATION}s"
  curl -sf --max-time $(( DURATION + 30 )) \
    "${url}/profile?seconds=${DURATION}" -o "${dir}/cpu.pb.gz" \
    || { fail "go: CPU profile fetch failed"; return 1; }
  ok "go: cpu.pb.gz"

  if (( HEAP )); then
    curl -sf --max-time 30 "${url}/heap" -o "${dir}/heap.pb.gz" && ok "go: heap.pb.gz" || true
    curl -sf --max-time 30 "${url}/goroutine?debug=2" -o "${dir}/goroutines.txt" && ok "go: goroutines.txt" || true
    curl -sf --max-time 30 "${url}/allocs" -o "${dir}/allocs.pb.gz" || true
  fi

  # go tool pprof renders SVG directly, but needs graphviz for the graph view.
  # -raw gives us folded-ish output with no external dependency at all, which is
  # what profile-diff.sh consumes.
  if command -v go >/dev/null 2>&1; then
    go tool pprof -top -nodecount=40 "${dir}/cpu.pb.gz" > "${dir}/cpu-top.txt" 2>/dev/null || true
    if go tool pprof -svg -output "${dir}/cpu.svg" "${dir}/cpu.pb.gz" >/dev/null 2>&1; then
      ok "go: cpu.svg (call graph — needs graphviz)"
    else
      note '- `go tool pprof -svg` failed; install graphviz (`apt install graphviz`) for the call-graph SVG.'
    fi
    # Folded stacks for the flamegraph and for profile-diff.sh.
    if go tool pprof -traces "${dir}/cpu.pb.gz" 2>/dev/null \
        | awk '/^-+\+-+$/ { if (n>0 && stack != "") print stack, n; stack=""; n=0; next }
               /^ *[0-9]/ { n=$1; gsub(/[^0-9]/,"",n); f=$2; stack=(stack==""?f:stack ";" f); next }
               /^ +/ { f=$1; stack=(stack==""?f:stack ";" f) }
               END { if (stack != "") print stack, n }' > "${dir}/cpu.folded" 2>/dev/null; then
      [[ -s "${dir}/cpu.folded" ]] && fold_to_svg "${dir}/cpu.folded" "${dir}/cpu-flame.svg" \
        && ok "go: cpu-flame.svg"
    fi
  else
    note '- The Go toolchain is not installed here, so only the raw `cpu.pb.gz` was saved.'
    note '  Render it anywhere with Go available:'
    note '  ```'
    note "  go tool pprof -http=:8080 ${OUT_BASE}/${PROFILE_TS}/go/cpu.pb.gz"
    note '  ```'
    note '  or without installing Go:'
    note '  ```'
    note "  docker run --rm -it -p 8080:8080 -v \"\$PWD/${OUT_BASE}/${PROFILE_TS}/go:/p\" \\"
    note '    golang:1.25 go tool pprof -http=0.0.0.0:8080 /p/cpu.pb.gz'
    note '  ```'
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Rust — pprof-rs endpoint, else perf
# ─────────────────────────────────────────────────────────────────────────────
profile_rust() {
  local dir="$1" base="$2" port; port="$(pprof_port rust)"
  local url="http://localhost:${port}/debug/pprof/profile?seconds=${DURATION}"

  if endpoint_alive "http://localhost:${port}/debug/pprof/"; then
    step "rust: pprof-rs endpoint, ${DURATION}s"
    if curl -sf --max-time $(( DURATION + 30 )) "${url}" -o "${dir}/cpu.pb.gz"; then
      ok "rust: cpu.pb.gz (pprof protobuf — open with go tool pprof or pprof.me)"
      curl -sf --max-time $(( DURATION + 30 )) \
        "http://localhost:${port}/debug/pprof/flamegraph?seconds=${DURATION}" \
        -o "${dir}/cpu.svg" 2>/dev/null && ok "rust: cpu.svg" || true
      return 0
    fi
  fi

  warn "rust: no pprof-rs endpoint on :${port} — falling back to perf"
  local pid; pid="$(container_pid "$(impl_container rust)")"
  if [[ -n "${pid}" && "${pid}" != "0" ]] && command -v perf >/dev/null 2>&1; then
    step "rust: perf record -F 99 -p ${pid} for ${DURATION}s"
    if perf record -F 99 -g -p "${pid}" -o "${dir}/perf.data" -- sleep "${DURATION}" >/dev/null 2>&1; then
      perf script -i "${dir}/perf.data" > "${dir}/perf.script" 2>/dev/null || true
      if command -v stackcollapse-perf.pl >/dev/null 2>&1; then
        stackcollapse-perf.pl "${dir}/perf.script" > "${dir}/cpu.folded" 2>/dev/null || true
      elif command -v inferno-collapse-perf >/dev/null 2>&1; then
        inferno-collapse-perf < "${dir}/perf.script" > "${dir}/cpu.folded" 2>/dev/null || true
      fi
      [[ -s "${dir}/cpu.folded" ]] && fold_to_svg "${dir}/cpu.folded" "${dir}/cpu.svg" && ok "rust: cpu.svg"
      ok "rust: perf.data"
      note '- Captured with `perf`. Symbols will be poor unless the binary was built with'
      note '  frame pointers and debug info:'
      note '  ```toml'
      note '  # rust/Cargo.toml'
      note '  [profile.release]'
      note '  debug = 1            # line tables; costs image size, not speed'
      note '  ```'
      note '  ```'
      note '  RUSTFLAGS="-C force-frame-pointers=yes" cargo build --release'
      note '  ```'
      note '  Without frame pointers a release build inlines and omits them, and the'
      note '  flamegraph collapses into a handful of enormous unnamed frames.'
      return 0
    fi
  fi

  fail "rust: no profile captured"
  note '## Rust — no profiler available'
  note ''
  note 'Neither a `pprof-rs` HTTP endpoint nor a usable `perf` was found.'
  note ''
  note '**Option A — pprof-rs endpoint** (preferred; works in a container with no'
  note 'extra privileges):'
  note ''
  note '```toml'
  note '# rust/Cargo.toml'
  note 'pprof = { version = "0.14", features = ["flamegraph", "protobuf-codec"] }'
  note '```'
  note ''
  note '```rust'
  note '// A separate axum Router on 127.0.0.1:6061, mounted only when'
  note '// PROFILING_ENABLED=true. Never on the public port.'
  note 'async fn pprof_profile(Query(q): Query<Secs>) -> impl IntoResponse {'
  note '    let guard = pprof::ProfilerGuardBuilder::default()'
  note '        .frequency(99)'
  note '        // Skipping libc/vdso frames keeps the graph readable.'
  note '        .blocklist(&["libc", "libgcc", "pthread", "vdso"])'
  note '        .build().unwrap();'
  note '    tokio::time::sleep(Duration::from_secs(q.seconds)).await;'
  note '    let report = guard.report().build().unwrap();'
  note '    let mut buf = Vec::new();'
  note '    report.flamegraph(&mut buf).unwrap();'
  note '    ([(header::CONTENT_TYPE, "image/svg+xml")], buf)'
  note '}'
  note '```'
  note ''
  note '**Option B — perf on the host:**'
  note ''
  note '```'
  note 'sudo perf record -F 99 -g -p $(docker inspect -f "{{.State.Pid}}" taskflow-rust) -- sleep 30'
  note 'perf script | stackcollapse-perf.pl | flamegraph.pl > cpu.svg'
  note '```'
  note ''
  note 'perf needs `kernel.perf_event_paranoid <= 1` and, from inside a container,'
  note '`--cap-add SYS_ADMIN`. Get the tools with:'
  note '`cargo install inferno` (inferno-collapse-perf / inferno-flamegraph).'
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Python — py-spy
# ─────────────────────────────────────────────────────────────────────────────
profile_python() {
  local dir="$1" base="$2"
  local container; container="$(impl_container python)"
  local pid; pid="$(container_pid "${container}")"

  if command -v py-spy >/dev/null 2>&1 && [[ -n "${pid}" && "${pid}" != "0" ]]; then
    step "python: py-spy record --pid ${pid} for ${DURATION}s"
    # --subprocesses matters: uvicorn/gunicorn run workers, and profiling the
    # supervisor shows you a process that does nothing but wait.
    if py-spy record --pid "${pid}" --duration "${DURATION}" --rate 99 \
        --subprocesses --format flamegraph --output "${dir}/cpu.svg" >/dev/null 2>&1; then
      ok "python: cpu.svg"
      py-spy record --pid "${pid}" --duration 5 --rate 99 --subprocesses \
        --format raw --output "${dir}/cpu.folded" >/dev/null 2>&1 || true
      py-spy dump --pid "${pid}" > "${dir}/threads.txt" 2>/dev/null || true
      return 0
    fi
  fi

  # Containerised fallback: py-spy in a sidecar sharing the target's PID
  # namespace. Needs SYS_PTRACE, which is why it is not on by default.
  if have_docker && container_running "${container}"; then
    step "python: py-spy via a sidecar container sharing the PID namespace"
    if docker run --rm --pid="container:${container}" --cap-add SYS_PTRACE \
        -v "${dir}:/out" benfred/py-spy:latest \
        record --pid 1 --duration "${DURATION}" --rate 99 --subprocesses \
        --format flamegraph --output /out/cpu.svg >/dev/null 2>&1; then
      ok "python: cpu.svg (via sidecar)"
      return 0
    fi
  fi

  fail "python: no profile captured"
  note '## Python — py-spy not available'
  note ''
  note '`py-spy` is a SAMPLING profiler that reads another process'"'"'s memory from'
  note 'outside it. Nothing has to be added to the application, and the overhead is'
  note 'a couple of percent — which is why it is the right tool here and'
  note '`cProfile` is not (cProfile is deterministic, instruments every call, and'
  note 'can slow a service by 2-5x, changing the very behaviour you are measuring).'
  note ''
  note '```'
  note 'pip install py-spy'
  note 'PID=$(docker inspect -f "{{.State.Pid}}" taskflow-python)'
  note 'sudo py-spy record --pid $PID --duration 30 --subprocesses --output cpu.svg'
  note '```'
  note ''
  note 'Or with no host install at all:'
  note ''
  note '```'
  note 'docker run --rm --pid=container:taskflow-python --cap-add SYS_PTRACE \'
  note '  -v "$PWD:/out" benfred/py-spy record --pid 1 --duration 30 --output /out/cpu.svg'
  note '```'
  note ''
  note '`--subprocesses` is not optional for uvicorn/gunicorn: without it you profile'
  note 'the supervisor process, which spends 100% of its time in `waitpid`.'
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# C# — dotnet-trace
# ─────────────────────────────────────────────────────────────────────────────
profile_csharp() {
  local dir="$1" base="$2"
  local container; container="$(impl_container csharp)"

  # Preferred: dotnet-trace inside the container, attached to PID 1.
  if have_docker && container_running "${container}" \
     && docker exec "${container}" sh -c 'command -v dotnet-trace' >/dev/null 2>&1; then
    step "csharp: dotnet-trace collect, ${DURATION}s"
    if docker exec "${container}" dotnet-trace collect --process-id 1 \
        --duration "00:00:$(printf '%02d' "${DURATION}")" \
        --profile cpu-sampling --format Speedscope \
        --output /tmp/cpu.speedscope.json >/dev/null 2>&1; then
      docker cp "${container}:/tmp/cpu.speedscope.json" "${dir}/cpu.speedscope.json" >/dev/null 2>&1 \
        && ok "csharp: cpu.speedscope.json (open at https://speedscope.app)"
      return 0
    fi
  fi

  if command -v dotnet-trace >/dev/null 2>&1; then
    local pid; pid="$(container_pid "${container}")"
    if [[ -n "${pid}" && "${pid}" != "0" ]]; then
      step "csharp: dotnet-trace from the host, pid ${pid}"
      dotnet-trace collect --process-id "${pid}" \
        --duration "00:00:$(printf '%02d' "${DURATION}")" \
        --profile cpu-sampling --format Speedscope \
        --output "${dir}/cpu.speedscope.json" >/dev/null 2>&1 \
        && { ok "csharp: cpu.speedscope.json"; return 0; }
    fi
  fi

  fail "csharp: no profile captured"
  note '## C# — dotnet-trace not available'
  note ''
  note 'The image is chiselled (no shell, no SDK), so `dotnet-trace` has to be'
  note 'either baked in for the benchmark build or run from the host against the'
  note 'container'"'"'s diagnostic socket.'
  note ''
  note '**Bake it into a benchmark-only stage** (`csharp/Dockerfile`):'
  note ''
  note '```dockerfile'
  note 'FROM mcr.microsoft.com/dotnet/sdk:10.0 AS profiler'
  note 'RUN dotnet tool install --tool-path /tools dotnet-trace \'
  note ' && dotnet tool install --tool-path /tools dotnet-counters \'
  note ' && dotnet tool install --tool-path /tools dotnet-gcdump'
  note ''
  note '# ...in the runtime stage, only for the profiling variant:'
  note 'COPY --from=profiler /tools /tools'
  note 'ENV PATH="/tools:${PATH}" DOTNET_EnableDiagnostics=1'
  note '```'
  note ''
  note '`DOTNET_EnableDiagnostics=1` is required — the diagnostics IPC socket is'
  note 'off in many hardened base images, and without it `dotnet-trace` reports'
  note '"process not found" even though the process is plainly there.'
  note ''
  note '**From the host** (share /tmp so the socket is visible):'
  note ''
  note '```'
  note 'dotnet tool install -g dotnet-trace'
  note 'dotnet-trace collect --process-id $(docker inspect -f "{{.State.Pid}}" taskflow-csharp) \'
  note '  --duration 00:00:30 --profile cpu-sampling --format Speedscope'
  note '```'
  note ''
  note 'Speedscope JSON opens at https://speedscope.app (entirely client-side —'
  note 'the file is never uploaded). `.nettrace` output opens in PerfView on'
  note 'Windows or `dotnet-trace convert`.'
  note ''
  note 'For heap: `dotnet-gcdump collect -p <pid>`, then open in Visual Studio or'
  note '`dotnet-gcdump report`.'
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# TypeScript / Node — --cpu-prof or the inspector
# ─────────────────────────────────────────────────────────────────────────────
profile_typescript() {
  local dir="$1" base="$2"
  local container; container="$(impl_container typescript)"
  local port; port="$(pprof_port typescript)"

  # If the inspector is already listening we can drive it over CDP without
  # restarting anything, which is the only non-disruptive option Node offers.
  if endpoint_alive "http://localhost:${port}/json/version"; then
    step "typescript: inspector on :${port} — capturing via CDP for ${DURATION}s"
    if command -v node >/dev/null 2>&1; then
      if node "${SCRIPT_DIR}/lib/node-cpuprofile.mjs" \
           "http://localhost:${port}" "${DURATION}" "${dir}/cpu.cpuprofile" >/dev/null 2>&1; then
        ok "typescript: cpu.cpuprofile (open in Chrome DevTools → Performance → Load)"
        return 0
      fi
    fi
  fi

  fail "typescript: no profile captured"
  note '## TypeScript / Node — no CPU profile'
  note ''
  note 'Node has two ways to produce a CPU profile, and they trade off differently:'
  note ''
  note '**A. `--cpu-prof`** — simple, but the profile is only WRITTEN ON EXIT, so'
  note 'the process must be restarted and then stopped. Fine for a benchmark run,'
  note 'useless for a live incident.'
  note ''
  note '```yaml'
  note '  typescript-api:'
  note '    environment:'
  note '      NODE_OPTIONS: "--cpu-prof --cpu-prof-dir=/tmp/prof --max-old-space-size=1536"'
  note '    tmpfs: ["/tmp:size=256M"]   # the default 64M will truncate the profile'
  note '```'
  note '```'
  note 'docker compose up -d --force-recreate typescript-api'
  note '# ...generate load...'
  note 'docker stop -t 30 taskflow-typescript      # SIGTERM → profile is flushed'
  note 'docker cp taskflow-typescript:/tmp/prof ./profiles/'
  note '```'
  note ''
  note '**B. The inspector protocol** — attach and detach at will, no restart:'
  note ''
  note '```yaml'
  note '  typescript-api:'
  note '    environment:'
  note '      # 127.0.0.1, never 0.0.0.0: an open inspector port is remote code'
  note '      # execution, full stop.'
  note '      NODE_OPTIONS: "--inspect=127.0.0.1:9229"'
  note '    ports: ["9229:9229"]        # benchmark environment ONLY'
  note '```'
  note '```'
  note 'node scripts/lib/node-cpuprofile.mjs http://localhost:9229 30 cpu.cpuprofile'
  note '```'
  note ''
  note 'Either way the output is a `.cpuprofile`, which Chrome DevTools opens under'
  note 'Performance → Load. For a flamegraph SVG instead, `npx speedscope cpu.cpuprofile`.'
  note ''
  note 'Heap: `node --heapsnapshot-signal=SIGUSR2` then `docker kill -s SIGUSR2`, or'
  note '`v8.writeHeapSnapshot()` from an admin route.'
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────
declare -a CAPTURED=() MISSING=()

for impl in "${IMPLS[@]}"; do
  section "${impl}"
  dir="${OUT_DIR}/${impl}"
  mkdir -p "${dir}"
  NOTES="${dir}/notes.md"
  : > "${NOTES}"
  base="$(impl_base_url "${impl}")"

  {
    echo "# ${impl} — profile capture $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "- duration: ${DURATION}s"
    echo "- load: $( ((NO_LOAD)) && echo 'none (--no-load)' || echo "${LOAD_RATE} rps read-heavy" )"
    echo
  } >> "${NOTES}"

  if [[ "$(http_status "${base}/api/v1/health/live" 3)" != "200" ]]; then
    warn "${impl}: not running at ${base} — skipping"
    note "Service was not running at ${base}; nothing captured."
    MISSING+=("${impl}")
    continue
  fi

  if service_is_501 "${base}"; then
    warn "${impl}: service returns 501 — implement Phase 1 first"
    step "A profile of the 501 handler shows you JSON encoding and nothing else."
    note 'Service answers 501 NOT_IMPLEMENTED on /api/v1/tasks, so the load'
    note 'generator could not exercise any real code path. Implement Phase 1 first;'
    note 'profiling the error handler tells you only about JSON encoding.'
    MISSING+=("${impl}")
    continue
  fi

  # PROFILING_ENABLED gates the endpoints in the service itself.
  penv="$(docker inspect "$(impl_container "${impl}")" \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
          | awk -F= '/^PROFILING_ENABLED=/ {print $2}' | tail -1 || true)"
  if [[ -n "${penv}" && "${penv}" != "true" ]]; then
    warn "${impl}: PROFILING_ENABLED=${penv} — profiling endpoints are probably off"
    step "PROFILING_ENABLED=true docker compose up -d --force-recreate $(impl_service "${impl}")"
    note "PROFILING_ENABLED was \`${penv}\` at capture time."
  fi

  start_load "${base}" "${DURATION}"
  rc=0
  case "${impl}" in
    go)         profile_go "${dir}" "${base}" || rc=1 ;;
    rust)       profile_rust "${dir}" "${base}" || rc=1 ;;
    python)     profile_python "${dir}" "${base}" || rc=1 ;;
    csharp)     profile_csharp "${dir}" "${base}" || rc=1 ;;
    typescript) profile_typescript "${dir}" "${base}" || rc=1 ;;
  esac
  stop_load

  if (( rc == 0 )); then CAPTURED+=("${impl}"); else MISSING+=("${impl}"); fi
done

# ─────────────────────────────────────────────────────────────────────────────
# profiles/<ts>/README.md — how to read what you just captured
# ─────────────────────────────────────────────────────────────────────────────
cat > "${OUT_DIR}/README.md" <<'READMEEOF'
# Reading these profiles

## How to read a flamegraph

A flamegraph is **not** a timeline. The x-axis is not time; it is sorted
alphabetically so that identical stacks merge into one wide block.

- **Width = total time spent in that frame** (itself plus everything it called).
  Width is the only thing that matters. A frame occupying 40% of the width
  accounts for 40% of the samples.
- **Depth = call-stack depth.** A tall, thin tower is a deep call chain that
  costs almost nothing. It looks dramatic and is almost always irrelevant.
- **y-axis direction is a convention.** Flamegraphs grow upward from `main`;
  *icicle* graphs (Chrome DevTools, speedscope's default) grow downward. Same
  data, flipped.
- **Colour is usually meaningless** — random, chosen to make adjacent blocks
  distinguishable. Some tools use it to encode language or module; check the
  legend before reading anything into it.

### The method

1. Ignore the top of the graph. Start at the bottom and find the widest block
   whose name you recognise.
2. Walk upward into its widest child, repeatedly. That path is where the time
   goes.
3. Stop when you reach something you can change.

### What is normal and not a bug

- **`epoll_wait` / `kevent` / `io_uring_enter` occupying most of the graph** on
  an idle or IO-bound service. That is the event loop waiting for work. If you
  captured with `--no-load`, expect the entire graph to be this.
- **Syscall and TLS frames under every HTTP handler.** That is the network.
- **Wide, flat allocator frames** (`malloc`, `runtime.mallocgc`, `GC.Alloc`).
  Interesting only relative to the other implementations.

### What to actually look for

- A **single wide leaf** you did not expect — JSON serialisation, a regex, a
  UUID formatter, a logger. This is the common finding, and usually a one-line
  fix.
- **Lock or channel frames** wide near the bottom: contention, not work.
- **The database call being narrow.** If `pq`/`pgx`/`asyncpg` is only 10% of the
  graph while p95 is 200 ms, the time is spent WAITING for a pool connection,
  not executing the query. Cross-check `db_client_connection_pending_requests` —
  saturation, not utilisation, is the number that reveals this.
- **Anything TLS-related** when you thought the connection was plaintext.

## Per language

### Go — `cpu.pb.gz`, `heap.pb.gz`, `goroutines.txt`

```
go tool pprof -http=:8080 cpu.pb.gz     # interactive: graph, flame, top, source
go tool pprof -top -cum cpu.pb.gz       # text
```

`-cum` (cumulative) sorts by time spent in a function *and everything it
called*; flat sorts by time in the function itself. Read `-cum` to find the
subsystem, flat to find the hot loop.

Look for: `runtime.mallocgc` and `runtime.gcBgMarkWorker` (allocation pressure —
usually per-request allocations that could be pooled or avoided);
`runtime.selectgo`/`runtime.chansend` (channel contention);
`encoding/json.Marshal` (frequently the single biggest non-database cost in a
JSON API).

`goroutines.txt` is the leak detector: a goroutine count that grows monotonically
across successive captures is a leak, and the stack trace tells you exactly which
`go func()` never returns.

### Rust — `cpu.pb.gz` / `cpu.svg` / `perf.data`

```
go tool pprof -http=:8080 cpu.pb.gz            # pprof-rs emits pprof protobuf
perf report -i perf.data                       # perf fallback
```

Symbols are the whole game here. A release build without
`-C force-frame-pointers=yes` and `debug = 1` produces a flamegraph of
unresolved addresses and enormous inlined frames. If your graph looks
suspiciously shallow, that is why.

Look for: `serde_json` serialisation; `tokio::runtime` scheduling overhead
(usually small — if it is large you have too many tiny tasks);
`alloc::` frames (Rust has no GC, but `Vec`/`String` growth still costs);
`sqlx`/`tokio_postgres` statement preparation, which shows up when prepared
statements are not being reused.

### Python — `cpu.svg`, `threads.txt`

py-spy samples from outside the process, so there is nothing to add to the code
and the overhead is 1-2%. Use it, not `cProfile`: cProfile instruments every
call, can slow a service 2-5x, and therefore changes the behaviour you are
trying to measure.

Look for: the GIL — wide `wait_for_tstate_lock` / `acquire` frames mean threads
are queueing, not working; `asyncio` event-loop frames dominating (that is
usually fine, it is the loop waiting); anything in `pydantic` validation, which
is often the largest non-database cost in a FastAPI service; `psycopg`/`asyncpg`
row parsing.

`threads.txt` (`py-spy dump`) is the async-deadlock tool: it shows what every
thread and every coroutine is doing right now.

### C# — `cpu.speedscope.json`

Open at <https://speedscope.app> — it runs entirely in the browser, the file is
never uploaded. Or `dotnet-trace convert --format Chromium`.

Look for: `System.Text.Json` serialisation; tiered-JIT frames
(`Tier0`/`OSR` methods) — if you see many, the warm-up was too short and the
profile is describing the JIT rather than the code; GC frames
(`gc_heap::mark_phase`) — with `DOTNET_gcServer=1` some GC cost is expected and
parallel; `Npgsql` command execution.

The JIT point is not a footnote. Profiling a .NET service for 30 s after a cold
start mostly profiles compilation. Warm up first; `scripts/benchmark.sh` does.

### TypeScript / Node — `cpu.cpuprofile`

Chrome DevTools → Performance → Load, or `npx speedscope cpu.cpuprofile`.

Look for: `(garbage collector)` — a single visible frame in Node's profiles;
`JSON.stringify`; frames marked `(program)` or `(idle)` (event loop waiting —
normal); anything synchronous in a request path, since one blocking call stalls
*every* concurrent request rather than just its own. That last one is Node's
characteristic failure mode and it is visible in a flamegraph as one moderately
wide synchronous frame with terrible p99 to match.

Cross-check `runtime_event_loop_lag_seconds`. A profile that looks idle while
p99 is dreadful means the loop is being blocked in a frame too short to sample
often but long enough to matter.

## Comparing across languages — carefully

Do **not** compare absolute widths between two languages' flamegraphs. The
sampling rates differ, the symbolisation differs, and inlining differs. Compare
*shapes* and *proportions*: "serialisation is 22% here and 4% there" is a real
observation; "this frame is 3 ms wider" is not.

And remember what the benchmark says: most of TaskFlow's latency is Postgres,
which is identical for all five. If the database frames are the widest thing in
every graph, that is the correct answer, not a failure to find something.

## See also

- `scripts/profile-diff.sh` — capture with the cache on and off and list the
  frames that disappeared. It connects the profiling story directly to the
  Redis story: the frames that vanish ARE the work the cache removed.
- `benchmarks/README.md` — measurement methodology.
- Brendan Gregg, *Flame Graphs*: <https://www.brendangregg.com/flamegraphs.html>
READMEEOF

{
  echo
  echo "---"
  echo
  echo "## This capture"
  echo
  echo "- timestamp: ${PROFILE_TS}"
  echo "- duration: ${DURATION}s per implementation"
  echo "- load: $( ((NO_LOAD)) && echo 'none' || echo "${LOAD_RATE} rps read-heavy via k6" )"
  echo "- captured: ${CAPTURED[*]:-none}"
  echo "- missing: ${MISSING[*]:-none}"
  echo
  echo "Each implementation's \`notes.md\` explains what was captured and, where"
  echo "nothing was, the exact change needed to make it possible."
} >> "${OUT_DIR}/README.md"

section "done"
ok "profiles → ${OUT_BASE}/${PROFILE_TS}/"
ok "guide    → ${OUT_BASE}/${PROFILE_TS}/README.md"
(( ${#CAPTURED[@]} )) && ok "captured: ${CAPTURED[*]}"
(( ${#MISSING[@]} )) && warn "no profile: ${MISSING[*]} (see each notes.md for the fix)"
exit 0
