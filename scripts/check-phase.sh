#!/usr/bin/env bash
#
# check-phase.sh — "have I finished this phase in this language?"
#
#   scripts/check-phase.sh 1 go            # phase 1, Go only
#   scripts/check-phase.sh 1               # phase 1, all five
#   scripts/check-phase.sh 4 rust -x       # stop at the first failure
#   scripts/check-phase.sh 0 all --fast    # skip the slow/docker tests
#
# Exit status is the verdict: 0 means the phase is complete for the selected
# implementation(s), non-zero means it is not.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASES_MAX=11
IMPLS=(go rust python csharp typescript)

# Phases with no conformance tests, by design: "is this profile good?" and "is
# this write-up honest?" are not booleans. They are gated on tooling output
# instead, so pytest's "no tests ran" needs to read as expected, not as a typo.
#
# A case statement rather than an associative array: this is the command you run
# a hundred times a day, and it must not be the one script that refuses to start
# on the bash macOS ships.
phase_without_tests() { # <n>  → "title|gate", or empty
  case "$1" in
    8)  echo "Load Testing & Profiling|make bench · make soak · make profile · make bench-cache" ;;
    11) echo "Synthesis|the write-up itself — see docs/learning-roadmap.md" ;;
  esac
}

usage() {
  cat <<'USAGE'
usage: check-phase.sh <phase> [impl] [pytest args...]

  <phase>   0-11, or the marker name (phase3), or "all"
  [impl]    go | rust | python | csharp | typescript | all   (default: all)

options (anything else is passed straight through to pytest):
  --fast    deselect the slow and docker-dependent tests
  --list    collect only; show what would run without running it
  -x        stop on the first failure
  -n auto   run in parallel (every test is hermetic)

examples:
  check-phase.sh 0                  # does the skeleton still stand up?
  check-phase.sh 1 go               # is Go's core API finished?
  check-phase.sh 4 python --fast    # phase 4 without the rate-limit soak
  check-phase.sh all go             # everything, Go only
USAGE
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit "$([[ $# -lt 1 ]] && echo 2 || echo 0)"
fi

RAW_PHASE="$1"; shift

IMPL="all"
if [[ $# -gt 0 && "$1" != -* ]]; then
  IMPL="$1"; shift
fi

# ── resolve the marker expression ───────────────────────────────────────────
if [[ "$RAW_PHASE" == "all" ]]; then
  MARKER=""
  PHASE_LABEL="every phase"
else
  PHASE_NUM="${RAW_PHASE#phase}"
  if ! [[ "$PHASE_NUM" =~ ^[0-9]+$ ]] || (( PHASE_NUM > PHASES_MAX )); then
    echo "error: '$RAW_PHASE' is not a phase. Use 0-${PHASES_MAX}, phaseN, or all." >&2
    exit 2
  fi
  # Say so before spending a pytest run to discover it.
  untested="$(phase_without_tests "$PHASE_NUM")"
  if [[ -n "$untested" ]]; then
    title="${untested%%|*}"
    gate="${untested#*|}"
    echo "──────────────────────────────────────────────────────────────"
    echo "  TaskFlow · phase ${PHASE_NUM} — ${title}"
    echo "──────────────────────────────────────────────────────────────"
    echo
    echo "  This phase has no conformance tests, on purpose."
    echo "  Its gate is:  ${gate}"
    echo
    echo "  Nothing to check here. See docs/learning-roadmap.md."
    exit 0
  fi

  MARKER="phase${PHASE_NUM}"
  PHASE_LABEL="phase ${PHASE_NUM}"
  # The differential test is the cross-implementation contract check. It is
  # written once and re-run at every phase from 1 onwards.
  if (( PHASE_NUM >= 1 )) && [[ "$IMPL" == "all" ]]; then
    MARKER="${MARKER} or differential"
  fi
fi

# ── validate the implementation ─────────────────────────────────────────────
if [[ "$IMPL" != "all" ]]; then
  found=0
  for known in "${IMPLS[@]}"; do [[ "$IMPL" == "$known" ]] && found=1; done
  if (( ! found )); then
    echo "error: unknown implementation '$IMPL'. Choose from: ${IMPLS[*]}, all." >&2
    exit 2
  fi
fi

PYTEST_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --fast) PYTEST_ARGS+=(-m "not slow and not docker") ;;
    --list) PYTEST_ARGS+=(--collect-only -q) ;;
    *)      PYTEST_ARGS+=("$arg") ;;
  esac
done

# --fast composes with the phase marker rather than replacing it.
FINAL_ARGS=()
skip_next=0
extra_marker=""
for i in "${!PYTEST_ARGS[@]}"; do
  if (( skip_next )); then skip_next=0; continue; fi
  if [[ "${PYTEST_ARGS[$i]}" == "-m" ]]; then
    extra_marker="${PYTEST_ARGS[$((i + 1))]}"
    skip_next=1
    continue
  fi
  FINAL_ARGS+=("${PYTEST_ARGS[$i]}")
done

if [[ -n "$MARKER" && -n "$extra_marker" ]]; then
  MARKER="(${MARKER}) and (${extra_marker})"
elif [[ -n "$extra_marker" ]]; then
  MARKER="$extra_marker"
fi

CMD=(python3 -m pytest "${ROOT}/tests")
[[ -n "$MARKER" ]] && CMD+=(-m "$MARKER")
CMD+=(--impl "$IMPL")
# Guarded on length: under `set -u`, expanding an empty array is an error in
# bash before 4.4 — including the 3.2 that macOS ships. Unguarded, the plain
# `check-phase.sh 0` with no extra pytest arguments died on "unbound variable"
# before running a single test.
(( ${#FINAL_ARGS[@]} )) && CMD+=("${FINAL_ARGS[@]}")

echo "──────────────────────────────────────────────────────────────"
echo "  TaskFlow · ${PHASE_LABEL} · ${IMPL}"
echo "  ${CMD[*]}"
echo "──────────────────────────────────────────────────────────────"

set +e
"${CMD[@]}"
STATUS=$?
set -e

echo
# --collect-only lists tests; it does not judge them.
for arg in ${FINAL_ARGS[@]+"${FINAL_ARGS[@]}"}; do
  if [[ "$arg" == "--collect-only" ]]; then
    echo "  (collect-only: nothing was executed)"
    exit $STATUS
  fi
done

# pytest exits 0 when every test SKIPPED, which is what happens when the
# service isn't running. Reporting that as PASS would be a false green — the
# worst possible outcome for a gate whose entire job is to tell you the truth
# about your progress. Inspect the recorded status instead of trusting the
# exit code alone.
UNREACHABLE=0
if [[ $STATUS -eq 0 && -f "${ROOT}/reports/phase-status.json" ]]; then
  UNREACHABLE=$(python3 - "$ROOT/reports/phase-status.json" "${PHASE_NUM:-all}" "$IMPL" <<'PY' || echo 0
import json, sys
path, phase, impl = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    doc = json.load(open(path))
except Exception:
    print(0); raise SystemExit
# "all" means "all CONFIGURED" — a one-language project must not be judged
# against four languages it deliberately turned off.
if impl == "all":
    targets = ["go", "rust", "python", "csharp", "typescript"]
    try:
        for line in open(__import__("os").path.join(
                __import__("os").path.dirname(path), "..", ".env")):
            if line.startswith("COMPOSE_PROFILES="):
                chosen = {x.strip() for x in line.split("=", 1)[1].split(",")}
                narrowed = [t for t in targets if t in chosen]
                if narrowed:
                    targets = narrowed
                break
    except OSError:
        pass
else:
    targets = [impl]
entries = []
for pname, pdata in (doc.get("phases") or {}).items():
    if phase != "all" and pname != f"phase{phase}":
        continue
    for lang, e in (pdata.get("implementations") or {}).items():
        if lang in targets and isinstance(e, dict):
            entries.append(e)
# Unreachable iff nothing actually ran anywhere we asked about.
print(1 if entries and all(
    e.get("verdict") == "unreachable"
    or (e.get("passed", 0) == 0 and e.get("failed", 0) == 0
        and e.get("unreachable", 0) > 0)
    for e in entries
) else 0)
PY
)
fi

if [[ $STATUS -eq 0 && "${UNREACHABLE}" == "1" ]]; then
  echo "  ! ${PHASE_LABEL} was NOT verified — no service responded (${IMPL})."
  echo "    Every test was skipped, which is not the same as passing."
  echo "    Start the stack first:   make up      (or: make up-one IMPL=${IMPL})"
  echo "    Then check what's up:    make status"
  STATUS=3
else
  case $STATUS in
    0) echo "  ✓ ${PHASE_LABEL} PASSES for: ${IMPL}" ;;
    1) echo "  ✗ ${PHASE_LABEL} is NOT complete for: ${IMPL}"
       echo "    Tests marked NOT IMPLEMENTED are endpoints you have not built yet."
       echo "    Tests marked NOT REACHABLE mean the service is not running." ;;
    5) echo "  ! no tests matched. Did you mean a different phase?" ;;
    *) echo "  ! pytest exited with status ${STATUS}" ;;
  esac
fi
echo "    Full status: ${ROOT}/reports/phase-status.json  (scripts/progress.sh)"

exit $STATUS
