#!/usr/bin/env bash
#
# init-repo.sh — re-point every GitHub reference at YOUR fork.
#
# The upstream repository hardcodes `lazartony/taskflow` in badge URLs, clone
# commands, Discussion links, CODEOWNERS and the Code of Conduct's reporting
# link. Leaving placeholders there instead would have meant a README with
# `GITHUB_OWNER` in the badges — worse for everyone. So the references are real,
# and this script rewrites them for your fork.
#
# It works out where your fork lives from `git remote get-url origin`, so
# usually you need no arguments at all.
#
#   scripts/init-repo.sh                    # detect from git remote
#   scripts/init-repo.sh you/my-taskflow    # or say it explicitly
#   scripts/init-repo.sh --dry-run          # show the diff, change nothing
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

# Whatever owner/repo the references in this tree currently point at. Must be
# updated whenever they are, or a fork of a fork finds nothing to rewrite and
# reports "already initialised" while leaving every link aimed upstream.
UPSTREAM="lazartony/taskflow"
DRY_RUN=0
TARGET=""

usage() {
  sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage 0 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -*)          die "unknown option '$1' (try --help)" ;;
    *)           TARGET="$1"; shift ;;
  esac
done

# ── work out where this fork lives ──────────────────────────────────────────
if [[ -z "$TARGET" ]]; then
  remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote" ]]; then
    die "no git remote 'origin' found. Either add one, or pass the target explicitly:
    scripts/init-repo.sh your-username/your-repo"
  fi
  # Handles both  git@github.com:owner/repo.git  and  https://github.com/owner/repo(.git)
  TARGET="$(printf '%s' "$remote" \
    | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
  step "detected from origin: ${TARGET}"
fi

if [[ ! "$TARGET" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "'${TARGET}' does not look like owner/repo"
fi

NEW_OWNER="${TARGET%%/*}"
NEW_REPO="${TARGET##*/}"
OLD_OWNER="${UPSTREAM%%/*}"

if [[ "$TARGET" == "$UPSTREAM" ]]; then
  ok "already pointing at ${UPSTREAM} — nothing to do"
  exit 0
fi

# ── find every file that mentions the upstream ──────────────────────────────
# This script is excluded on purpose: it stores the upstream name in
# $UPSTREAM, and rewriting that would break the script for anyone who runs it
# a second time (or who forks a fork).
FILES=()
while IFS= read -r __f; do
  [[ -n "$__f" ]] && FILES+=("$__f")
done < <(
  grep -rIl -e "${UPSTREAM}" -e "@${OLD_OWNER}" "$ROOT" \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=__pycache__ \
    --exclude=init-repo.sh \
    2>/dev/null | sort
)

if (( ${#FILES[@]} == 0 )); then
  ok "no references to ${UPSTREAM} found — already initialised?"
  exit 0
fi

echo
echo "  ${UPSTREAM}  →  ${TARGET}"
echo
for f in "${FILES[@]}"; do
  rel="${f#"$ROOT"/}"
  n=$(grep -c -e "${UPSTREAM}" -e "@${OLD_OWNER}" "$f" || true)
  printf '    %-46s %s reference(s)\n' "$rel" "$n"
done
echo

if (( DRY_RUN )); then
  warn "dry run — nothing was written"
  echo "  Re-run without --dry-run to apply."
  exit 0
fi

# ── rewrite ─────────────────────────────────────────────────────────────────
# Order matters: replace the full owner/repo pair FIRST, so a repo named after
# the owner (`alice/alice`) can't be mangled by the bare-owner rule below.
#
# The @owner rule avoids `\b`. GNU sed has it; BSD sed (macOS) does not, and
# there it matches nothing at all — so `make init-repo` used to rewrite the badge
# and clone URLs while leaving every @owner mention in CODEOWNERS pointing at the
# upstream author, which silently assigns a fork's reviews to a stranger.
# Two expressions instead: one for a mention followed by anything that cannot be
# part of a username, one for a mention at end of line.
for f in "${FILES[@]}"; do
  tmp="$(mktemp)"
  sed -e "s|${UPSTREAM}|${NEW_OWNER}/${NEW_REPO}|g" \
      -e "s|@${OLD_OWNER}\\([^A-Za-z0-9._-]\\)|@${NEW_OWNER}\\1|g" \
      -e "s|@${OLD_OWNER}\$|@${NEW_OWNER}|g" \
      "$f" > "$tmp"
  # Preserve the executable bit; mktemp files are 0600.
  if [[ -x "$f" ]]; then chmod +x "$tmp"; else chmod 644 "$tmp"; fi
  mv "$tmp" "$f"
done

ok "rewrote ${#FILES[@]} file(s)"

# ── what this does NOT touch, and why ───────────────────────────────────────
cat <<EOF

  Not changed, deliberately:

    NOTICE.md            third-party licences — nothing to do with your fork
    go/go.mod            the Go module path is internal; the module is never
                         published, and renaming it means touching every import
    container names      taskflow-go, taskflow-db … these are local, not public

  Do check, because these are NOT rewritten automatically:

    docs/openapi.yaml    info.contact.url — rewritten only if it already matched
                         the owner above. It is what Swagger/Redoc shows as the
                         project's home, so it is worth a look.

  Worth doing next:

    git diff                        check it looks right
    make validate                   confirm nothing broke
    GITHUB_TOKEN=\$(gh auth token) make pin-actions

  Then read PUBLISHING.md for the GitHub settings that aren't in any file —
  branch protection, secret scanning, and private vulnerability reporting.
  That last one is load-bearing: the Code of Conduct's reporting link 404s
  until it is switched on.
EOF
