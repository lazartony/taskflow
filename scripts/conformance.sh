#!/usr/bin/env bash
#
# conformance.sh — does each implementation actually obey docs/openapi.yaml?
#
# Two different questions, asked in order:
#
#   1. Schemathesis, per implementation. Property-based: it reads the OpenAPI
#      document, generates requests the document says are legal, and checks the
#      responses against what the document promises. It finds the cases nobody
#      writes a test for — the empty string, the 300-character title, the
#      integer where a string was expected — and it finds them per language.
#
#   2. The differential test, across all five at once. Schemathesis can pass on
#      all five while the five disagree with each other, because "conforms to
#      the schema" leaves room: one returns 404 and another 403, one paginates
#      from 0 and another from 1. C5 says the five must be interchangeable, and
#      only a differential test can say whether they are.
#
# A skeleton returns 501 to everything. Fuzzing it produces hundreds of
# identical "expected 200, got 501" failures and no information at all, so the
# 501 state is detected up front and reported as "not implemented yet".
#
#   scripts/conformance.sh
#   scripts/conformance.sh --impl go --max-examples 200
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SCHEMATHESIS_IMAGE="${SCHEMATHESIS_IMAGE:-schemathesis/schemathesis:stable}"
IMPL="all"
MAX_EXAMPLES=50
CHECKS="all"
RUN_DIFFERENTIAL=1
SCHEMA="docs/openapi.yaml"
REPORT_DIR="reports"

usage() {
  cat <<'EOF'
conformance.sh — property-based conformance for all five implementations

USAGE
  scripts/conformance.sh [options]

OPTIONS
  --impl <lang>        go | rust | python | csharp | typescript | all  (default all)
  --max-examples N     test cases generated per API operation (default 50).
                       50 is a smoke test; 500 is a real hunt and takes minutes
  --checks LIST        Schemathesis checks (default 'all')
  --no-differential    skip the cross-implementation comparison
  --schema PATH        OpenAPI document (default docs/openapi.yaml)
  -h, --help

OUTPUT
  reports/schemathesis-<impl>.xml   JUnit, one file per implementation
  reports/differential.xml          JUnit for the cross-implementation test

REQUIREMENTS
  The stack must be running:  make up
  Schemathesis runs from its own image; no pip install needed.

EXIT STATUS
  0  every implementation that was tested, conformed
  1  at least one did not
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --impl)            IMPL="${2:?--impl needs a value}"; shift 2 ;;
    --max-examples)    MAX_EXAMPLES="${2:?--max-examples needs a number}"; shift 2 ;;
    --checks)          CHECKS="${2:?--checks needs a value}"; shift 2 ;;
    --no-differential) RUN_DIFFERENTIAL=0; shift ;;
    --schema)          SCHEMA="${2:?--schema needs a path}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

[[ "${MAX_EXAMPLES}" =~ ^[0-9]+$ && "${MAX_EXAMPLES}" -gt 0 ]] \
  || { fail "--max-examples must be a positive integer"; exit 2; }
if [[ "${IMPL}" != "all" ]] && ! is_impl "${IMPL}"; then
  fail "unknown implementation '${IMPL}' (expected: ${IMPLS_ALL[*]}, all)"
  exit 2
fi
[[ -f "${REPO_ROOT}/${SCHEMA}" ]] || die "no OpenAPI document at ${SCHEMA}"

require_docker
mkdir -p "${REPO_ROOT}/${REPORT_DIR}"

TARGETS=()
if [[ "${IMPL}" == "all" ]]; then TARGETS=("${IMPLS_ALL[@]}"); else TARGETS=("${IMPL}"); fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
summary_reset

# ─────────────────────────────────────────────────────────────────────────────
# A throwaway account per implementation
# ─────────────────────────────────────────────────────────────────────────────
#
# Unauthenticated fuzzing tests exactly one thing: that everything returns 401.
# Every interesting response shape is behind auth, so each implementation gets
# its own fresh user — its own, because a shared user would let one run's
# generated DELETEs remove another run's tasks and produce failures that look
# like non-conformance.
#
# The password satisfies the schema's own pattern (lower, upper, digit, >=8).
register_token() { # <base-url> → prints the access token, or nothing
  local base="$1" email body
  email="conformance-$(date +%s)-${RANDOM}@taskflow.test"
  body="$(curl -sS --max-time 15 -X POST "${base}/api/v1/auth/register" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"${email}\",\"password\":\"ConformPass123\",\"displayName\":\"Conformance Bot\"}" \
      2>/dev/null || true)"
  # The envelope is {data:{user, tokens:{accessToken,...}}} — see
  # tests/load/lib/auth.js, which parses the same shape.
  printf '%s' "${body}" | jq -r '.data.tokens.accessToken // empty' 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# JUnit summarising
# ─────────────────────────────────────────────────────────────────────────────
junit_counts() { # <file> → "tests failures errors skipped"
  python3 - "$1" <<'PY' 2>/dev/null || printf '0 0 0 0'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    print("0 0 0 0"); raise SystemExit(0)
suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
t = f = e = s = 0
for su in suites:
    t += int(su.get("tests", 0)); f += int(su.get("failures", 0))
    e += int(su.get("errors", 0)); s += int(su.get("skipped", 0))
print(f"{t} {f} {e} {s}")
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# Schemathesis
# ─────────────────────────────────────────────────────────────────────────────
SCHEMATHESIS_MODE=""

detect_schemathesis() {
  [[ -n "${SCHEMATHESIS_MODE}" ]] && return 0
  if command -v schemathesis >/dev/null 2>&1; then
    SCHEMATHESIS_MODE=local
    step "schemathesis: local ($(schemathesis --version 2>/dev/null | head -1))"
    return 0
  fi
  if ensure_image "${SCHEMATHESIS_IMAGE}"; then
    SCHEMATHESIS_MODE=docker
    step "schemathesis: ${SCHEMATHESIS_IMAGE} via Docker"
    return 0
  fi
  return 1
}

run_schemathesis() { # <impl> <base-url> <token> <junit-path-relative-to-repo>
  local impl="$1" base="$2" token="$3" junit="$4"
  local -a args=(
    run "${SCHEMA}"
    --url "${base}/api/v1"
    --checks "${CHECKS}"
    --max-examples "${MAX_EXAMPLES}"
    --report junit
    --report-junit-path "${junit}"
    # Deterministic-ish and self-contained: no example database carried
    # between runs, so a failure reported today reproduces tomorrow.
    --generation-database none
    --continue-on-failure
    --no-color
  )
  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")

  if [[ "${SCHEMATHESIS_MODE}" == "local" ]]; then
    ( cd "${REPO_ROOT}" && schemathesis "${args[@]}" )
  else
    # --network host because the URLs are localhost:800x from the host's point
    # of view; --user so the JUnit file lands owned by the caller.
    docker run --rm --network host \
      --user "$(id -u):$(id -g)" \
      -v "${REPO_ROOT}:/repo" -w /repo \
      -e HOME=/tmp \
      "${SCHEMATHESIS_IMAGE}" "${args[@]}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Per implementation
# ─────────────────────────────────────────────────────────────────────────────
section "schemathesis (${MAX_EXAMPLES} examples per operation)"

if ! detect_schemathesis; then
  die_hint "schemathesis is not available" \
    "It normally runs from ${SCHEMATHESIS_IMAGE}, which could not be pulled." \
    "Install locally instead:  pip install schemathesis" \
    "(tests/conformance/requirements.txt lists the pinned version.)"
fi

ANY_TESTED=0
for impl in "${TARGETS[@]}"; do
  base="$(impl_base_url "${impl}")"
  container="$(impl_container "${impl}")"
  junit_rel="${REPORT_DIR}/schemathesis-${impl}.xml"
  junit_abs="${REPO_ROOT}/${junit_rel}"
  rm -f "${junit_abs}"

  printf '\n' >&2
  info "── ${impl} @ ${base}"

  # 1. is it there at all?
  if [[ "$(http_status "${base}/api/v1/health/live" 3)" != "200" ]]; then
    if container_exists "${container}"; then
      fail "${impl}: container exists but /health/live does not answer"
      step "Look at why:  docker compose logs --tail=50 $(impl_service "${impl}")"
      summary_add "${impl}" FAIL "no answer on /health/live"
    else
      warn "${impl}: not running"
      step "Start it:  make up-one IMPL=${impl}   (or make up for all five)"
      summary_add "${impl}" SKIP "not running"
    fi
    continue
  fi

  # 2. is it built, or is it still the Phase 0 catch-all?
  #
  # Fuzzing a skeleton produces one failure per generated case and teaches
  # nothing. Say so once instead.
  if service_is_501 "${base}"; then
    warn "${impl}: not implemented yet — GET /api/v1/tasks returns 501"
    step "The Phase 0 catch-all is still mounted, so every generated request"
    step "would fail identically. Nothing was run."
    step "See docs/learning-roadmap.md Phase 1."
    summary_add "${impl}" SKIP "501 skeleton — not implemented yet"
    continue
  fi

  # 3. a token
  token="$(register_token "${base}")"
  if [[ -z "${token}" ]]; then
    warn "${impl}: could not register a throwaway user — testing unauthenticated"
    step "POST ${base}/api/v1/auth/register did not return .data.tokens.accessToken."
    step "Every authenticated operation will report 401; that is the auth"
    step "endpoint's problem, not a conformance finding on the rest."
  else
    step "registered a throwaway user"
  fi

  # 4. run it
  ANY_TESTED=1
  rc=0
  run_schemathesis "${impl}" "${base}" "${token}" "${junit_rel}" \
    >"${TMP}/${impl}.log" 2>&1 || rc=$?

  read -r t f e s <<<"$(junit_counts "${junit_abs}")"
  detail="${t} cases"
  [[ "${s}" != "0" ]] && detail="${detail}, ${s} skipped"

  if (( rc == 0 )); then
    ok "${impl}: conforms (${detail})"
    summary_add "${impl}" PASS "${detail}"
  else
    fail "${impl}: ${f} failure(s), ${e} error(s) out of ${t}"
    # The tail is where Schemathesis prints its grouped summary; the middle is
    # thousands of lines of generated payloads nobody reads.
    tail -40 "${TMP}/${impl}.log" | sed 's/^/        /' >&2
    step "Full output preserved at ${junit_rel}"
    summary_add "${impl}" FAIL "${f} failures, ${e} errors of ${t}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Differential
# ─────────────────────────────────────────────────────────────────────────────
#
# Only meaningful with more than one implementation live: comparing go with
# itself always passes.
if (( RUN_DIFFERENTIAL )) && [[ "${IMPL}" == "all" ]]; then
  section "differential (all five compared with each other)"

  live=0
  for impl in "${IMPLS_ALL[@]}"; do
    [[ "$(http_status "$(impl_base_url "${impl}")/api/v1/health/live" 3)" == "200" ]] \
      && live=$(( live + 1 ))
  done

  if (( live < 2 )); then
    warn "only ${live} implementation(s) are up — nothing to compare"
    step "The differential test needs at least two:  make up"
    summary_add "differential" SKIP "${live} implementations up"
  elif ! python3 -c 'import pytest' >/dev/null 2>&1; then
    warn "pytest is not installed — skipping the differential test"
    step "Install it:  pip install -r tests/conformance/requirements.txt"
    summary_add "differential" SKIP "pytest not installed"
  else
    rc=0
    ( cd "${REPO_ROOT}" && python3 -m pytest tests/conformance/test_differential.py \
        -v --impl all --junitxml="${REPORT_DIR}/differential.xml" ) \
      >"${TMP}/differential.log" 2>&1 || rc=$?
    read -r t f e s <<<"$(junit_counts "${REPO_ROOT}/${REPORT_DIR}/differential.xml")"
    if (( rc == 0 )); then
      ok "all five agree (${t} comparisons)"
      summary_add "differential" PASS "${t} comparisons"
    elif (( rc == 5 )); then
      warn "no differential tests were collected"
      summary_add "differential" SKIP "no tests collected"
    else
      fail "the implementations disagree — ${f} failure(s) of ${t}"
      tail -40 "${TMP}/differential.log" | sed 's/^/        /' >&2
      step "This is requirement C5: the five must be interchangeable."
      summary_add "differential" FAIL "${f} disagreements of ${t}"
    fi
  fi
elif (( RUN_DIFFERENTIAL )); then
  info "differential test skipped — it compares implementations, and --impl was ${IMPL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
summary_print "conformance"

printf '  %sJUnit reports: %s/%s%s\n\n' "${C_DIM}" "${REPORT_DIR}" "schemathesis-<impl>.xml" "${C_RESET}" >&2

FAILED="$(summary_count FAIL)"
PASSED="$(summary_count PASS)"
SKIPPED="$(summary_count SKIP)"

if (( FAILED > 0 )); then
  fail "${FAILED} did not conform, ${PASSED} did, ${SKIPPED} skipped"
  exit 1
fi
if (( ! ANY_TESTED )); then
  warn "nothing was actually tested — is the stack up? (make up)"
  exit 1
fi
ok "${PASSED} conformed, ${SKIPPED} skipped"
exit 0
