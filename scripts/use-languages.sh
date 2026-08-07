#!/usr/bin/env bash
#
# use-languages.sh — choose which language implementations this project uses.
#
# Five languages is the default, and it is the more interesting project. But
# one language is a fully supported path, not a degraded one: you still get the
# whole harness — phase gates, load tests, the cache A/B, profiling, chaos — and
# you get to a finished, production-shaped service about five times sooner.
#
# This rewrites one line in .env (COMPOSE_PROFILES). It deletes nothing. The
# other language directories stay exactly where they are, and widening again is
# the same command.
#
#   scripts/use-languages.sh go             # Go only
#   scripts/use-languages.sh go,rust        # two
#   scripts/use-languages.sh all            # all five
#   scripts/use-languages.sh                # show the current selection
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

ENV_FILE="${ROOT}/.env"
ALL=(go rust python csharp typescript)

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
  die ".env does not exist yet. Run 'make setup' first."
fi

current() {
  grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# ── no argument: report and exit ─────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  cur="$(current)"
  if [[ -z "$cur" ]]; then
    warn "COMPOSE_PROFILES is not set in .env — no API services will start."
    echo "  Fix with:  make languages LANGS=all"
    exit 1
  fi
  echo
  echo "  Active languages: ${cur//,/ }"
  echo
  for l in "${ALL[@]}"; do
    if [[ ",${cur}," == *",${l},"* ]]; then
      printf '    %b●%b %-12s %bactive%b\n' "$C_GREEN" "$C_RESET" "$l" "$C_DIM" "$C_RESET"
    else
      printf '    %b○ %-12s idle — directory still on disk%b\n' "$C_DIM" "$l" "$C_RESET"
    fi
  done
  echo
  echo "  Change with:  make languages LANGS=go        (or go,rust  or  all)"
  echo
  exit 0
fi

# ── resolve the requested set ────────────────────────────────────────────────
REQ="$1"
if [[ "$REQ" == "all" ]]; then
  SELECTED=("${ALL[@]}")
else
  IFS=',' read -r -a SELECTED <<< "${REQ// /}"
  for l in "${SELECTED[@]}"; do
    is_impl "$l" || die "unknown language '$l' (expected: ${ALL[*]}, or 'all')"
  done
fi

JOINED="$(IFS=,; echo "${SELECTED[*]}")"
PREVIOUS="$(current)"

# ── rewrite the single line ──────────────────────────────────────────────────
if grep -qE '^COMPOSE_PROFILES=' "$ENV_FILE"; then
  # Portable in-place edit: BSD and GNU sed disagree about -i.
  tmp="$(mktemp)"
  sed "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${JOINED}|" "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
else
  printf '\n# Which language implementations are active (scripts/use-languages.sh)\nCOMPOSE_PROFILES=%s\n' "$JOINED" >> "$ENV_FILE"
fi

echo
ok "active languages: ${JOINED//,/ }"
[[ -n "$PREVIOUS" && "$PREVIOUS" != "$JOINED" ]] && echo "  (was: ${PREVIOUS//,/ })"

# Services that are no longer in the selection keep running until you say so —
# silently orphaning containers is worse than one extra instruction.
STALE=()
for l in "${ALL[@]}"; do
  [[ ",${JOINED}," == *",${l},"* ]] && continue
  container_exists "taskflow-${l}" && STALE+=("$l")
done

if (( ${#STALE[@]} )); then
  echo
  warn "still running from the previous selection: ${STALE[*]}"
  echo "  Stop them with:  docker compose stop $(printf '%s-api ' "${STALE[@]}")"
fi

echo
echo "  Next:  make up   then   make check PHASE=0"
echo
