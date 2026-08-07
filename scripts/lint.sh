#!/usr/bin/env bash
#
# lint.sh — run each language's linters without installing any of them.
#
# Five languages means five toolchains, and "install Go, Rust, Python, .NET and
# Node before you can lint" is how a repo ends up with nobody linting anything.
# Every check below runs in the language's own container, against the source
# bind-mounted read-write (formatters need to be able to write, even in
# --check mode some of them do). Build caches live in named volumes so the
# second run is not another cold `cargo build`.
#
# What runs, per language — the lint and build steps of .github/workflows/ci.yml:
#
#   go          gofmt -l . · go vet ./... · golangci-lint run
#   rust        cargo fmt --check · cargo clippy --all-targets -- -D warnings
#   python      ruff format --check · ruff check · mypy app
#   csharp      dotnet format --verify-no-changes · dotnet build
#   typescript  prettier --check · tsc --noEmit · eslint
#
# Not everything CI runs is here: the per-language test and vulnerability-scan
# steps (go test -race, govulncheck, cargo audit, pytest, bandit, dotnet list
# package --vulnerable, npm test) need a toolchain this script deliberately does
# not assume. eslint is the reverse — offered here, not in CI, and skipped until
# the repo grows a flat config.
#
# A language whose image will not pull is SKIPPED with the reason, not failed.
#
#   scripts/lint.sh go
#   scripts/lint.sh all
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Pinned. An unpinned linter image is a build that breaks on a Tuesday for
# reasons that have nothing to do with your commit.
#
# golangci-lint must be v2.x: go/.golangci.yml is a v2 config, and v1 reads the
# `linters.enable` list but silently ignores v2's `linters.settings` and
# `linters.exclusions` — so it lints with the right linters and the wrong
# configuration, which is worse than refusing to start.
#
# The Rust tag must satisfy the MSRV in rust/Cargo.toml, not merely be old
# enough to "prove" the MSRV: clippy resolves the same Cargo.lock the release
# build does, and a lockfile entry that needs a newer rustc fails here first.
GO_IMAGE="${GO_LINT_IMAGE:-golangci/golangci-lint:v2.6-alpine}"
RUST_IMAGE="${RUST_LINT_IMAGE:-rust:1.88-slim}"
PYTHON_IMAGE="${PYTHON_LINT_IMAGE:-python:3.11-slim}"
CSHARP_IMAGE="${CSHARP_LINT_IMAGE:-mcr.microsoft.com/dotnet/sdk:9.0}"
NODE_IMAGE="${NODE_LINT_IMAGE:-node:22-alpine}"

FIX=0
VERBOSE=0

usage() {
  cat <<'EOF'
lint.sh — lint one implementation, or all five, inside Docker

USAGE
  scripts/lint.sh <impl|all> [options]

  <impl>   go | rust | python | csharp | typescript | all

OPTIONS
  --fix        run the formatters in write mode instead of check mode
               (gofmt -w, cargo fmt, ruff format, dotnet format, prettier -w)
  -v, --verbose  show each tool's output even when it passes
  -h, --help

NOTES
  Nothing needs to be installed locally except Docker. First run per language
  pulls an image (200 MB - 1 GB for the .NET SDK) and populates a build cache
  volume; later runs are much faster.

  Caches:  taskflow-lint-<lang>  (docker volume ls)
           Remove with:  docker volume rm taskflow-lint-go ...

EXIT STATUS
  0  everything that ran, passed
  1  at least one linter failed
  2  bad arguments
EOF
}

TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)        FIX=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           fail "unknown option: $1"; echo; usage; exit 2 ;;
    *)            [[ -z "${TARGET}" ]] && TARGET="$1" || { fail "unexpected argument: $1"; exit 2; }; shift ;;
  esac
done

[[ -n "${TARGET}" ]] || { fail "which implementation? (go|rust|python|csharp|typescript|all)"; echo; usage; exit 2; }
if [[ "${TARGET}" != "all" ]] && ! is_impl "${TARGET}"; then
  fail "unknown implementation '${TARGET}' (expected: ${IMPLS_ALL[*]}, all)"
  exit 2
fi

require_docker

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
summary_reset

# ─────────────────────────────────────────────────────────────────────────────
# Running a tool in a language container
# ─────────────────────────────────────────────────────────────────────────────
#
# --user is deliberately NOT set. Several of these toolchains (cargo, dotnet,
# npm) want a writable HOME, and running as the caller's uid inside an image
# that has no matching passwd entry breaks them in ways whose error messages
# point nowhere near the cause. Instead, anything written back to the source
# tree is written as root — which is why --fix warns about it.
#
# lrun <image> <workdir-in-repo> <cache-volume> <shell command>
lrun() {
  local image="$1" workdir="$2" volname="$3" cmd="$4"
  local -a mounts=(-v "${REPO_ROOT}:/repo")
  [[ -n "${volname}" ]] && mounts+=(-v "${volname}:/cache")
  docker run --rm \
    "${mounts[@]}" \
    -w "/repo/${workdir}" \
    -e HOME=/cache \
    -e CARGO_HOME=/cache/cargo \
    -e GOPATH=/cache/go \
    -e GOCACHE=/cache/go-build \
    -e GOLANGCI_LINT_CACHE=/cache/golangci \
    -e GOFLAGS=-buildvcs=false \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    -e DOTNET_NOLOGO=1 \
    -e NUGET_PACKAGES=/cache/nuget \
    -e npm_config_cache=/cache/npm \
    -e XDG_CACHE_HOME=/cache \
    -e PIP_CACHE_DIR=/cache/pip \
    -e PYTHONDONTWRITEBYTECODE=1 \
    "${image}" \
    sh -c "${cmd}"
}

# One named tool inside one language. Records its own summary row.
run_tool() { # <impl> <tool label> <image> <workdir> <volume> <command>
  local impl="$1" label="$2" image="$3" workdir="$4" vol="$5" cmd="$6"
  local log="${TMP}/${impl}-${label// /_}.log" rc=0
  step "${label}"
  lrun "${image}" "${workdir}" "${vol}" "${cmd}" >"${log}" 2>&1 || rc=$?
  if (( rc == 0 )); then
    ok "${impl}: ${label}"
    (( VERBOSE )) && [[ -s "${log}" ]] && sed 's/^/        /' "${log}" >&2
    summary_add "${impl} · ${label}" PASS ""
    return 0
  fi
  fail "${impl}: ${label}"
  [[ -s "${log}" ]] && tail -40 "${log}" | sed 's/^/        /' >&2
  summary_add "${impl} · ${label}" FAIL "exit ${rc}"
  return 1
}

skip_lang() { # <impl> <reason>
  warn "${1}: skipped — ${2}"
  summary_add "${1}" SKIP "${2}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Go
# ─────────────────────────────────────────────────────────────────────────────
#
# The golangci-lint image carries a full Go toolchain, so one image covers
# gofmt, go vet and golangci-lint. gofmt is checked by listing files rather
# than diffing: `gofmt -l` prints the offenders, and an empty list is the pass.
lint_go() {
  section "go"
  [[ -d "${REPO_ROOT}/go" ]] || { skip_lang go "no go/ directory"; return 0; }
  ensure_image "${GO_IMAGE}" || { skip_lang go "could not pull ${GO_IMAGE}"; return 0; }

  local vol=taskflow-lint-go rc=0
  if (( FIX )); then
    run_tool go "gofmt -w" "${GO_IMAGE}" go "${vol}" 'gofmt -w .' || rc=1
  else
    run_tool go "gofmt" "${GO_IMAGE}" go "${vol}" \
      'out=$(gofmt -l .); if [ -n "$out" ]; then echo "not gofmt-clean:"; echo "$out"; exit 1; fi' || rc=1
  fi
  run_tool go "go vet" "${GO_IMAGE}" go "${vol}" 'go vet ./...' || rc=1
  run_tool go "golangci-lint" "${GO_IMAGE}" go "${vol}" 'golangci-lint run --timeout 5m ./...' || rc=1
  return "${rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Rust
# ─────────────────────────────────────────────────────────────────────────────
#
# The official rust image ships rustfmt and clippy, so no rustup component add
# is needed. clippy compiles the crate — the first run is slow and the cache
# volume is what stops that being true every time.
lint_rust() {
  section "rust"
  [[ -f "${REPO_ROOT}/rust/Cargo.toml" ]] || { skip_lang rust "no rust/Cargo.toml"; return 0; }
  ensure_image "${RUST_IMAGE}" || { skip_lang rust "could not pull ${RUST_IMAGE}"; return 0; }

  local vol=taskflow-lint-rust rc=0
  # CARGO_TARGET_DIR into the cache volume: writing target/ into the mounted
  # source tree as root leaves a directory the developer cannot delete.
  local pre='export CARGO_TARGET_DIR=/cache/target; rustup component add rustfmt clippy >/dev/null 2>&1 || true;'
  if (( FIX )); then
    run_tool rust "cargo fmt" "${RUST_IMAGE}" rust "${vol}" "${pre} cargo fmt" || rc=1
  else
    run_tool rust "cargo fmt --check" "${RUST_IMAGE}" rust "${vol}" "${pre} cargo fmt --check" || rc=1
  fi
  run_tool rust "cargo clippy" "${RUST_IMAGE}" rust "${vol}" \
    "${pre} cargo clippy --all-targets -- -D warnings" || rc=1
  return "${rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Python
# ─────────────────────────────────────────────────────────────────────────────
#
# ruff and mypy are installed into the cache volume on first run rather than
# baked into an image, because mypy needs the project's own dependencies to
# resolve imports — a standalone mypy image would report "module not found" for
# every third-party import and call it a hundred errors.
lint_python() {
  section "python"
  [[ -f "${REPO_ROOT}/python/pyproject.toml" ]] || { skip_lang python "no python/pyproject.toml"; return 0; }
  ensure_image "${PYTHON_IMAGE}" || { skip_lang python "could not pull ${PYTHON_IMAGE}"; return 0; }

  local vol=taskflow-lint-python rc=0
  local venv='/cache/venv'
  local pre="if [ ! -x ${venv}/bin/ruff ]; then python -m venv ${venv} >/dev/null && ${venv}/bin/pip install -q ruff mypy && ${venv}/bin/pip install -q -e '.[dev]' 2>/dev/null; fi; export PATH=${venv}/bin:\$PATH;"

  if (( FIX )); then
    run_tool python "ruff format" "${PYTHON_IMAGE}" python "${vol}" "${pre} ruff format ." || rc=1
    run_tool python "ruff check --fix" "${PYTHON_IMAGE}" python "${vol}" "${pre} ruff check --fix ." || rc=1
  else
    run_tool python "ruff format --check" "${PYTHON_IMAGE}" python "${vol}" "${pre} ruff format --check ." || rc=1
    run_tool python "ruff check" "${PYTHON_IMAGE}" python "${vol}" "${pre} ruff check ." || rc=1
  fi
  run_tool python "mypy" "${PYTHON_IMAGE}" python "${vol}" "${pre} mypy app" || rc=1
  return "${rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# C#
# ─────────────────────────────────────────────────────────────────────────────
lint_csharp() {
  section "csharp"
  [[ -d "${REPO_ROOT}/csharp" ]] || { skip_lang csharp "no csharp/ directory"; return 0; }
  ensure_image "${CSHARP_IMAGE}" || { skip_lang csharp "could not pull ${CSHARP_IMAGE} (~1 GB)"; return 0; }

  local vol=taskflow-lint-csharp rc=0
  run_tool csharp "dotnet restore" "${CSHARP_IMAGE}" csharp "${vol}" 'dotnet restore' || {
    summary_add "csharp" SKIP "restore failed — later checks not attempted"
    return 1
  }
  if (( FIX )); then
    run_tool csharp "dotnet format" "${CSHARP_IMAGE}" csharp "${vol}" 'dotnet format' || rc=1
  else
    run_tool csharp "dotnet format --verify" "${CSHARP_IMAGE}" csharp "${vol}" \
      'dotnet format --verify-no-changes' || rc=1
  fi
  run_tool csharp "dotnet build" "${CSHARP_IMAGE}" csharp "${vol}" \
    'dotnet build --no-restore -c Release' || rc=1
  return "${rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# TypeScript
# ─────────────────────────────────────────────────────────────────────────────
#
# `npm ci` needs package-lock.json and installs into node_modules INSIDE the
# mounted source tree — there is no clean way around that with npm. It is
# therefore written as root; the alternative (copying the tree into the
# container) makes `--fix` unable to write anything back.
lint_typescript() {
  section "typescript"
  [[ -f "${REPO_ROOT}/typescript/package.json" ]] || { skip_lang typescript "no typescript/package.json"; return 0; }
  ensure_image "${NODE_IMAGE}" || { skip_lang typescript "could not pull ${NODE_IMAGE}"; return 0; }

  local vol=taskflow-lint-typescript rc=0
  local pre='if [ ! -d node_modules ]; then (npm ci --no-audit --no-fund || npm install --no-audit --no-fund); fi;'

  if (( FIX )); then
    run_tool typescript "prettier --write" "${NODE_IMAGE}" typescript "${vol}" \
      "${pre} npx --yes prettier --write src" || rc=1
  else
    run_tool typescript "prettier --check" "${NODE_IMAGE}" typescript "${vol}" \
      "${pre} npx --yes prettier --check src" || rc=1
  fi
  run_tool typescript "tsc --noEmit" "${NODE_IMAGE}" typescript "${vol}" \
    "${pre} npx --yes tsc --noEmit" || rc=1
  # eslint is optional: the repo may not have a flat config yet, and "no
  # config found" is not a lint failure.
  run_tool typescript "eslint" "${NODE_IMAGE}" typescript "${vol}" \
    "${pre} if ls eslint.config.* .eslintrc* >/dev/null 2>&1; then npx --yes eslint src; else echo 'no eslint config — skipped'; fi" || rc=1
  return "${rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
if (( FIX )); then
  warn "--fix writes into your source tree from inside a container, as root"
  step "Files it rewrites will be owned by root. Fix afterwards with:"
  step "  sudo chown -R \$(id -u):\$(id -g) ${REPO_ROOT}"
fi

RC=0
if [[ "${TARGET}" == "all" ]]; then
  for impl in "${IMPLS_ALL[@]}"; do
    "lint_${impl}" || RC=1
  done
else
  "lint_${TARGET}" || RC=1
fi

summary_print "lint (${TARGET})"

FAILED="$(summary_count FAIL)"
SKIPPED="$(summary_count SKIP)"
PASSED="$(summary_count PASS)"

if (( FAILED > 0 )); then
  fail "${FAILED} check(s) failed, ${PASSED} passed, ${SKIPPED} skipped"
  exit 1
fi
if (( SKIPPED > 0 )); then
  warn "${PASSED} passed, ${SKIPPED} skipped — CI runs the skipped ones on a machine that can pull"
else
  ok "all ${PASSED} checks passed"
fi
exit "${RC}"
