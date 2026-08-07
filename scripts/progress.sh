#!/usr/bin/env bash
#
# progress.sh — the whole-project dashboard.
#
# Renders reports/phase-status.json, which the pytest reporter merges into after
# every run. Because it merges rather than overwrites, running
# `check-phase.sh 1 go` today and `check-phase.sh 2 rust` tomorrow leaves both
# results on the board.
#
#   scripts/progress.sh            # render whatever has been measured so far
#   scripts/progress.sh --refresh  # re-run every phase against every impl first
#   scripts/progress.sh --json     # print the raw status document
#   scripts/progress.sh --ci       # refresh, render, AND write a markdown
#                                  # summary for the CI job summary panel

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_FILE="${ROOT}/reports/phase-status.json"
MARKDOWN_FILE="${ROOT}/reports/phase-status.md"
RENDERER="${ROOT}/scripts/render_progress.py"
CI_MODE=0

case "${1:-}" in
  --refresh)
    "${ROOT}/scripts/check-phase.sh" all all --fast || true
    ;;
  --ci)
    # CI wants everything measured and a markdown artifact. A partially
    # implemented project SHOULD produce a partial report rather than a hard
    # failure — the report is the deliverable, not the exit code.
    CI_MODE=1
    export NO_COLOR=1
    "${ROOT}/scripts/check-phase.sh" all all --fast || true
    ;;
  --json)
    cat "$STATUS_FILE"
    exit 0
    ;;
  -h|--help)
    sed -n '3,14p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

if [[ ! -f "$STATUS_FILE" ]]; then
  cat <<EOF
No status recorded yet — ${STATUS_FILE} does not exist.

Run a phase first:
  scripts/check-phase.sh 0            # the skeleton, all five implementations
  scripts/check-phase.sh 1 go         # phase 1, Go only
EOF
  exit 1
fi

if [[ "$CI_MODE" -eq 1 ]]; then
  mkdir -p "${ROOT}/reports"
  {
    echo '## TaskFlow — phase status'
    echo
    echo '```'
    python3 "$RENDERER" "$STATUS_FILE" || true
    echo '```'
    echo
    echo "_Partial red is expected while phases are still being built — that is the progress signal._"
  } > "$MARKDOWN_FILE"
  cat "$MARKDOWN_FILE"
  exit 0
fi

exec python3 "$RENDERER" "$STATUS_FILE"
