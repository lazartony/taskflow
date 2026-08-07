#!/usr/bin/env bash
#
# validate.sh — everything CI's `validate` job does, on your machine, before
# you push.
#
#   OpenAPI 3.1     the contract all five implementations are measured against
#   compose config  every docker-compose*.yml parses and interpolates
#   YAML lint       observability/ (the configs that silently no-op when wrong)
#   shell lint      scripts/, via shellcheck -S warning
#   Lua syntax      the Valkey rate-limit function
#
# None of these need a local toolchain. Anything missing is run inside a small
# image built on first use (taskflow-validate:local, ~90 MB) and cached after
# that. A check whose tooling genuinely cannot be obtained is reported SKIP,
# not FAIL — a machine without network should still get the answers it can.
#
#   scripts/validate.sh
#   scripts/validate.sh --only openapi
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VALIDATE_IMAGE="${VALIDATE_IMAGE:-taskflow-validate:local}"
SHELLCHECK_IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:v0.10.0}"
YAMLLINT_IMAGE="${YAMLLINT_IMAGE:-cytopia/yamllint:latest}"
LUA_IMAGE="${LUA_IMAGE:-nickblah/lua:5.4-alpine}"
ONLY=""
VERBOSE=0

usage() {
  cat <<'EOF'
validate.sh — run CI's contract checks locally

USAGE
  scripts/validate.sh [--only <check>] [-v]

CHECKS
  openapi     docs/openapi.yaml is valid OpenAPI 3.1
  compose     every docker-compose*.yml parses (docker compose config)
  images      every pinned image tag actually exists in its registry
  yaml        yamllint over observability/ and .github/
  shell       shellcheck -S warning over scripts/
  lua         the Valkey rate-limit function compiles

OPTIONS
  --only <check>   run one of the names above
  -v, --verbose    print each tool's full output, not just the failures
  -h, --help

EXIT STATUS
  0  every check that ran, passed
  1  at least one check failed
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)      ONLY="${2:?--only needs a check name}"; shift 2 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

if [[ -n "${ONLY}" ]]; then
  case "${ONLY}" in
    openapi|compose|images|yaml|shell|lua) ;;
    *) fail "unknown check '${ONLY}'"; echo; usage; exit 2 ;;
  esac
fi

wanted() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
summary_reset

# ─────────────────────────────────────────────────────────────────────────────
# The fallback image
# ─────────────────────────────────────────────────────────────────────────────
#
# Only the OpenAPI check needs one: yamllint, shellcheck and lua all have
# published images, and pulling a ready-made image beats building one. This is
# built once and cached, so the cost is paid on the first run only.
#
# It is also the check most likely to be unavailable on a locked-down machine
# (the build needs PyPI, not just a registry), which is precisely why a failed
# build is a SKIP with an explanation and not a fatal error.
IMAGE_STATE=-1   # -1 not tried, 0 usable, 1 unusable

ensure_validate_image() {
  (( IMAGE_STATE >= 0 )) && return "${IMAGE_STATE}"
  if image_present "${VALIDATE_IMAGE}"; then IMAGE_STATE=0; return 0; fi
  if ! have_docker; then IMAGE_STATE=1; return 1; fi
  info "building ${VALIDATE_IMAGE} (first run only)"
  # Versions pinned for the same reason the test suite pins its dependencies:
  # a validator that changes underneath you turns "CI went red" into a hunt.
  if docker build -q -t "${VALIDATE_IMAGE}" -f - "${TMP}" >/dev/null 2>"${TMP}/build.log" <<'DOCKERFILE'
FROM python:3.12-alpine
RUN pip install --no-cache-dir \
      openapi-spec-validator==0.7.2 \
      PyYAML==6.0.2
WORKDIR /repo
DOCKERFILE
  then
    IMAGE_STATE=0
  else
    IMAGE_STATE=1
    warn "could not build ${VALIDATE_IMAGE}"
    [[ -s "${TMP}/build.log" ]] && tail -5 "${TMP}/build.log" >&2
    step "Usually a proxy or an offline machine. The other checks still run."
  fi
  return "${IMAGE_STATE}"
}

vrun() { # run a command inside the validate image, repo mounted read-only
  docker run --rm -v "${REPO_ROOT}:/repo:ro" -w /repo "${VALIDATE_IMAGE}" "$@"
}

# Print a tool's output: always on failure, only with -v on success.
show() {
  local file="$1" failed="$2"
  [[ -s "${file}" ]] || return 0
  if (( failed )) || (( VERBOSE )); then
    sed 's/^/        /' "${file}" >&2
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. OpenAPI 3.1
# ─────────────────────────────────────────────────────────────────────────────
#
# Kept byte-identical to the snippet in .github/workflows/ci.yml. If the two
# ever drift, the local run stops predicting the CI run and nobody trusts
# either of them.
read -r -d '' OPENAPI_PY <<'PY' || true
from openapi_spec_validator import validate
import yaml, sys
spec = yaml.safe_load(open('docs/openapi.yaml'))
validate(spec)
n = sum(len([k for k in v if k in ('get','post','put','patch','delete')])
        for v in spec['paths'].values())
print(f"OpenAPI {spec.get('openapi','?')} valid — {n} operations, "
      f"{len(spec['paths'])} paths, "
      f"{len(spec.get('components',{}).get('schemas',{}))} schemas")
PY

check_openapi() {
  section "OpenAPI 3.1"
  local out="${TMP}/openapi.log" rc=0 how=""

  if python3 -c 'import openapi_spec_validator, yaml' 2>/dev/null; then
    how="local python3"
    ( cd "${REPO_ROOT}" && python3 -c "${OPENAPI_PY}" ) >"${out}" 2>&1 || rc=$?
  elif ensure_validate_image; then
    how="${VALIDATE_IMAGE}"
    vrun python -c "${OPENAPI_PY}" >"${out}" 2>&1 || rc=$?
  else
    summary_add "openapi" SKIP "no local openapi-spec-validator and no usable image"
    warn "skipped: install with 'pip install openapi-spec-validator' or allow Docker to build"
    return 0
  fi

  step "via ${how}"
  if (( rc == 0 )); then
    ok "$(tail -1 "${out}")"
    summary_add "openapi" PASS "$(tail -1 "${out}")"
  else
    fail "docs/openapi.yaml is not valid"
    show "${out}" 1
    summary_add "openapi" FAIL "see output above"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. compose files
# ─────────────────────────────────────────────────────────────────────────────
#
# `config` does full interpolation, so this also catches an env var referenced
# with no default and no .env entry — which otherwise surfaces as a service
# starting with an empty password.
check_compose() {
  section "compose files"
  if ! have_docker; then
    summary_add "compose" SKIP "docker daemon unreachable"
    warn "skipped: the Docker daemon is not reachable"
    return 0
  fi

  # `-printf` is GNU-only: BSD find (macOS) rejects it, which used to make this
  # check report "no compose files" on every Mac. basename per line instead.
  local files=() f rc bad=0 n=0
  while IFS= read -r f; do files+=("${f##*/}"); done < <(
    find "${REPO_ROOT}" -maxdepth 1 -name 'docker-compose*.yml' | sort
  )
  if (( ${#files[@]} == 0 )); then
    summary_add "compose" FAIL "no docker-compose*.yml found"
    fail "no compose files in ${REPO_ROOT}"
    return 0
  fi

  for f in "${files[@]}"; do
    rc=0
    ( cd "${REPO_ROOT}" && docker compose -f "${f}" config --quiet ) >"${TMP}/compose.log" 2>&1 || rc=$?
    n=$(( n + 1 ))
    if (( rc == 0 )); then
      ok "${f}"
    else
      fail "${f}"
      show "${TMP}/compose.log" 1
      bad=$(( bad + 1 ))
    fi
  done

  if (( bad )); then
    summary_add "compose" FAIL "${bad} of ${n} files invalid"
  else
    summary_add "compose" PASS "${n} files"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. YAML
# ─────────────────────────────────────────────────────────────────────────────
#
# observability/ is the directory where a typo does the most damage and gives
# the least feedback: a mis-indented processor block means the collector starts
# happily and drops every span, and you find out three phases later when a
# trace you needed is not there.
#
# ADVISORY, never FAIL. CI runs this step with `|| true`, and a local check
# that is stricter than CI is worse than no local check — you learn to run it,
# it goes red over trailing whitespace, and you learn to ignore it. Findings
# are printed in full so you can act on them; the exit status is CI's.
YAMLLINT_CONF='{extends: relaxed, rules: {line-length: disable}}'
YAMLLINT_VIA=""

yamllint_run() { # <path...>  → writes to stdout, returns yamllint's status
  case "${YAMLLINT_VIA}" in
    local)  ( cd "${REPO_ROOT}" && yamllint -d "${YAMLLINT_CONF}" "$@" ) ;;
    image)  docker run --rm -v "${REPO_ROOT}:/data:ro" -w /data \
              "${YAMLLINT_IMAGE}" -d "${YAMLLINT_CONF}" "$@" ;;
    helper) vrun yamllint -d "${YAMLLINT_CONF}" "$@" ;;
  esac
}

# ── image tags ───────────────────────────────────────────────────────────────
# A tag that does not exist fails at `docker compose up`, minutes into a new
# user's first run, with an error that reads like their fault. It has happened
# here already: grafana/loki:3.8.0 was pinned from release notes but never
# published under that tag. Cheap to check, expensive to ship.
check_images() {
  section "image tags"
  if ! have_docker; then
    summary_add "images" SKIP "docker daemon unreachable"
    warn "skipped: the Docker daemon is not reachable"
    return 0
  fi

  local imgs=() img bad=0 n=0 limited=0 out rc
  while IFS= read -r img; do
    [[ "${img}" == taskflow-* ]] && continue   # built locally, never pulled
    imgs+=("${img}")
  done < <(grep -rhoE '^[[:space:]]*image:[[:space:]]*[a-z0-9./_-]+:[a-zA-Z0-9._-]+' \
             "${REPO_ROOT}"/docker-compose*.yml | sed -E 's/^[[:space:]]*image:[[:space:]]*//' | sort -u)

  for img in "${imgs[@]}"; do
    n=$(( n + 1 ))
    rc=1
    # Docker Hub rate-limits anonymous manifest lookups hard. Back off properly
    # rather than reporting a shared-IP user's rate limit as a broken tag —
    # a check that cries wolf gets ignored, which is worse than no check.
    # The rate limit is per-account, not per-image: once we have hit it, backing
    # off for every remaining image just makes `make validate` take minutes to
    # tell you the same thing. One attempt each from then on.
    local tries=3
    (( limited )) && tries=1

    for (( attempt = 1; attempt <= tries; attempt++ )); do
      if out="$(docker manifest inspect "${img}" 2>&1)"; then rc=0; break; fi
      case "${out}" in
        *toomanyrequests*|*"rate limit"*|*"429"*)
          if (( attempt < tries )); then sleep $(( attempt * 3 )); continue; fi
          rc=2 ;;                                  # rate limited, not missing
        *"unauthorized"*|*"denied"*)
          rc=2; break ;;                           # private, or needs login
        *)
          rc=1; break ;;                           # genuinely no such manifest
      esac
    done

    case "${rc}" in
      0) step "${img}" ;;
      2) limited=$(( limited + 1 ))
         warn "${img} — could not verify (rate limited or requires login)" ;;
      *) bad=$(( bad + 1 ))
         fail "${img} — no such manifest. The tag does not exist in the registry." ;;
    esac
  done

  if (( bad )); then
    summary_add "images" FAIL "${bad}/${n} tag(s) do not exist"
    return 1
  fi
  if (( limited )); then
    # Not a failure: nothing is known to be wrong, we just could not confirm.
    # `docker login` raises the anonymous limit and makes this deterministic.
    summary_add "images" WARN "$(( n - limited ))/${n} verified, ${limited} rate limited"
    warn "${limited} tag(s) unverified — run 'docker login' to raise the anonymous pull limit"
    return 0
  fi
  summary_add "images" PASS "${n} tags exist"
  ok "all ${n} image tags resolve"
  return 0
}

check_yaml() {
  section "YAML"
  if command -v yamllint >/dev/null 2>&1; then
    YAMLLINT_VIA=local
  elif have_docker && ensure_image "${YAMLLINT_IMAGE}"; then
    YAMLLINT_VIA=image
  else
    summary_add "yaml" SKIP "no local yamllint and ${YAMLLINT_IMAGE} would not pull"
    warn "skipped: pip install yamllint, or allow the image pull"
    return 0
  fi
  case "${YAMLLINT_VIA}" in
    local) step "via local yamllint" ;;
    *)     step "via ${YAMLLINT_IMAGE}" ;;
  esac

  local rc=0 findings=0
  yamllint_run observability/ .github/ >"${TMP}/yaml.log" 2>&1 || rc=$?
  findings="$(grep -cE '^ +[0-9]+:[0-9]+ ' "${TMP}/yaml.log" 2>/dev/null || true)"

  if (( rc == 0 )); then
    ok "observability/ and .github/ clean"
    summary_add "yaml" PASS "observability/ .github/"
  else
    warn "${findings} yamllint finding(s) — advisory, as in CI"
    show "${TMP}/yaml.log" 1
    summary_add "yaml" WARN "${findings} findings (CI does not fail on these)"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. shellcheck
# ─────────────────────────────────────────────────────────────────────────────
check_shell() {
  section "shell"
  local -a files=()
  local f
  while IFS= read -r f; do files+=("${f}"); done < <(
    ( cd "${REPO_ROOT}" && find scripts -name '*.sh' -type f | sort )
  )
  if (( ${#files[@]} == 0 )); then
    summary_add "shell" SKIP "no scripts/*.sh"
    return 0
  fi

  # bash -n first. The linter parses too, but a syntax error reported as one
  # more finding reads like a style nit; "line 42: syntax error" does not.
  # (Do not start a comment line with the linter's own name — it treats that
  # as a directive and reports SC1072 against this very file.)
  local syntax_bad=0
  for f in "${files[@]}"; do
    bash -n "${REPO_ROOT}/${f}" 2>"${TMP}/syn.log" || {
      fail "${f} is not valid bash"
      show "${TMP}/syn.log" 1
      syntax_bad=$(( syntax_bad + 1 ))
    }
  done

  local rc=0 how=""
  if command -v shellcheck >/dev/null 2>&1; then
    how="local shellcheck $(shellcheck --version | awk '/^version:/ {print $2}')"
    ( cd "${REPO_ROOT}" && shellcheck -S warning "${files[@]}" ) >"${TMP}/shell.log" 2>&1 || rc=$?
  elif have_docker && ensure_image "${SHELLCHECK_IMAGE}"; then
    how="${SHELLCHECK_IMAGE}"
    docker run --rm -v "${REPO_ROOT}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" \
      -S warning "${files[@]}" >"${TMP}/shell.log" 2>&1 || rc=$?
  else
    summary_add "shell" SKIP "shellcheck unavailable (${#files[@]} scripts unchecked)"
    warn "skipped: apt install shellcheck / brew install shellcheck, or allow the image pull"
    return 0
  fi

  step "via ${how}"
  if (( rc == 0 && syntax_bad == 0 )); then
    ok "${#files[@]} scripts clean at -S warning"
    summary_add "shell" PASS "${#files[@]} scripts"
  else
    fail "shellcheck findings"
    show "${TMP}/shell.log" 1
    summary_add "shell" FAIL "$(grep -c '^In .* line' "${TMP}/shell.log" || true) findings"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Lua
# ─────────────────────────────────────────────────────────────────────────────
#
# The first line of a Redis Function file is `#!lua name=taskflow`. That is a
# Redis directive, not a Lua shebang and not Lua syntax — luac rejects it. It
# has to be stripped before compiling, which is exactly what Valkey does when
# it loads the function.
check_lua() {
  section "Lua"
  local src="${REPO_ROOT}/infrastructure/valkey/functions/ratelimit.lua"
  if [[ ! -f "${src}" ]]; then
    summary_add "lua" SKIP "no ratelimit.lua"
    warn "skipped: ${src#"${REPO_ROOT}"/} does not exist"
    return 0
  fi

  local first; first="$(head -1 "${src}")"
  if [[ "${first}" != "#!lua name="* ]]; then
    warn "ratelimit.lua does not start with '#!lua name=<library>'"
    step "Valkey/Redis will refuse FUNCTION LOAD without that first line."
  fi
  tail -n +2 "${src}" > "${TMP}/rl.lua"

  local luac="" rc=0
  for c in luac5.4 luac5.3 luac; do
    command -v "${c}" >/dev/null 2>&1 && { luac="${c}"; break; }
  done

  if [[ -n "${luac}" ]]; then
    step "via local ${luac}"
    "${luac}" -p "${TMP}/rl.lua" >"${TMP}/lua.log" 2>&1 || rc=$?
  elif have_docker && ensure_image "${LUA_IMAGE}"; then
    step "via ${LUA_IMAGE}"
    docker run --rm --entrypoint luac -v "${TMP}/rl.lua:/rl.lua:ro" "${LUA_IMAGE}" \
      -p /rl.lua >"${TMP}/lua.log" 2>&1 || rc=$?
  else
    summary_add "lua" SKIP "no luac and ${LUA_IMAGE} would not pull"
    warn "skipped: apt install lua5.4, or allow the image pull"
    return 0
  fi

  if (( rc == 0 )); then
    ok "ratelimit.lua compiles ($(wc -l < "${TMP}/rl.lua" | tr -d ' ') lines after the directive)"
    summary_add "lua" PASS "ratelimit.lua"
  else
    fail "ratelimit.lua does not compile"
    show "${TMP}/lua.log" 1
    step "Line numbers are off by one: the '#!lua name=' directive was stripped."
    summary_add "lua" FAIL "syntax error"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
wanted openapi && check_openapi
wanted compose && check_compose
wanted images  && check_images
wanted yaml    && check_yaml
wanted shell   && check_shell
wanted lua     && check_lua

summary_print "validate"

FAILED="$(summary_count FAIL)"
SKIPPED="$(summary_count SKIP)"
WARNED="$(summary_count WARN)"
PASSED="$(summary_count PASS)"

if (( FAILED > 0 )); then
  fail "${FAILED} check(s) failed, ${PASSED} passed, ${WARNED} advisory, ${SKIPPED} skipped"
  exit 1
fi
if (( SKIPPED > 0 )); then
  warn "${PASSED} passed, ${WARNED} advisory, ${SKIPPED} skipped — CI will run the skipped ones too"
elif (( WARNED > 0 )); then
  ok "${PASSED} checks passed, ${WARNED} advisory (CI does not fail on those either)"
else
  ok "all ${PASSED} checks passed"
fi
exit 0
