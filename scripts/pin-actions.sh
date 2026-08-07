#!/usr/bin/env bash
#
# pin-actions.sh — replace every `uses: owner/repo@tag` in .github/workflows/
# with `uses: owner/repo@<40-char-sha> # tag`.
#
# WHY THIS IS NOT PEDANTRY
#
#   A Git tag is a mutable pointer. `uses: some/action@v4` means "whatever
#   commit that tag points at when the workflow runs", and anyone who can push
#   to that repository can move it.
#
#   In March 2025 tj-actions/changed-files was compromised. The attacker did
#   not publish a new version — they FORCE-PUSHED a malicious commit over the
#   existing tags, including the major-version tags (v35, v44, ...) that
#   everyone pins to precisely because they are supposed to be stable. Every
#   workflow referencing the action by tag started running the attacker's code
#   on its next run, dumping CI secrets into the build log where anyone with
#   read access to a public repo's logs could collect them. Roughly 23,000
#   repositories were affected. The same technique was used against
#   reviewdog/action-setup days earlier, which is how tj-actions was breached
#   in the first place.
#
#   A 40-character commit SHA cannot be moved. Pin by SHA, keep the tag in a
#   trailing comment so a human can still read the file, and let Dependabot
#   bump both together — it understands this exact format.
#
#   This does not make you immune (the commit you pin could already be
#   malicious) but it removes the entire class of "the thing I already
#   reviewed changed underneath me".
#
#   scripts/pin-actions.sh --dry-run
#   scripts/pin-actions.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Keys its per-implementation results in an associative array.
require_bash4

WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"
DRY_RUN=0
CHECK=0

usage() {
  cat <<'EOF'
pin-actions.sh — pin GitHub Actions to commit SHAs

USAGE
  scripts/pin-actions.sh [--dry-run | --check] [--dir PATH]

OPTIONS
  --dry-run     show what would change; write nothing
  --check       like --dry-run, but exit 1 if anything is still pinned by tag.
                Use this as a CI gate once the repository is public
  --dir PATH    workflow directory (default .github/workflows)
  -h, --help

AUTHENTICATION
  Uses `gh api` when the GitHub CLI is available and authenticated, otherwise
  curl against api.github.com.

  Unauthenticated requests are limited to 60 per hour. With a token it is
  5,000. Set one if you have more than a handful of actions:

    export GITHUB_TOKEN=ghp_...        (a fine-grained token with no scopes
                                        is enough — this only reads public
                                        commit SHAs)

WHAT IS SKIPPED
  ./local-actions        first-party, already at your commit
  docker://image:tag     not a Git ref; pin the image by digest instead
  already-40-char refs   idempotent, so this is safe to re-run

OFFLINE / MIRRORED SETUPS
  Set PIN_ACTIONS_RESOLVER to a command taking "<owner/repo> <ref>" on argv
  and printing a 40-character SHA. Used instead of the GitHub API.

EXIT STATUS
  0  done (or, with --dry-run, nothing to report)
  1  --check found unpinned actions, or a SHA could not be resolved
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --check)   CHECK=1; DRY_RUN=1; shift ;;
    --dir)     WORKFLOW_DIR="${2:?--dir needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

if [[ ! -d "${WORKFLOW_DIR}" ]]; then
  fail "no workflow directory at ${WORKFLOW_DIR}"
  step "Point at one with --dir, or create .github/workflows/."
  exit 2
fi

WORKFLOWS=()
while IFS= read -r f; do WORKFLOWS+=("${f}"); done < <(
  find "${WORKFLOW_DIR}" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f | sort
)
(( ${#WORKFLOWS[@]} )) || { warn "no workflow files in ${WORKFLOW_DIR}"; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# Resolving a ref to a SHA
# ─────────────────────────────────────────────────────────────────────────────
RESOLVER=""
detect_resolver() {
  if [[ -n "${PIN_ACTIONS_RESOLVER:-}" ]]; then
    RESOLVER="custom"
    step "resolver: ${PIN_ACTIONS_RESOLVER}"
    return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    RESOLVER="gh"
    step "resolver: gh api (authenticated)"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    RESOLVER="curl"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      step "resolver: curl + GITHUB_TOKEN (5,000 requests/hour)"
    else
      step "resolver: curl, unauthenticated (60 requests/hour)"
    fi
    return 0
  fi
  die_hint "no way to reach the GitHub API" \
    "Install gh (https://cli.github.com) or curl." \
    "Or point PIN_ACTIONS_RESOLVER at your own lookup command."
}

declare -A SHA_CACHE=()

# resolve <owner/repo> <ref> → 40-char sha on stdout, or nothing
#
# The `Accept: application/vnd.github.sha` media type makes the commits
# endpoint return the bare SHA as text/plain, so there is nothing to parse and
# no jq dependency for the curl path.
resolve() {
  local repo="$1" ref="$2" key="$1@$2" sha=""
  [[ -n "${SHA_CACHE[$key]:-}" ]] && { printf '%s' "${SHA_CACHE[$key]}"; return 0; }

  case "${RESOLVER}" in
    custom) sha="$(${PIN_ACTIONS_RESOLVER} "${repo}" "${ref}" 2>/dev/null | tr -d '[:space:]')" ;;
    gh)     sha="$(gh api "repos/${repo}/commits/${ref}" --jq '.sha' 2>/dev/null | tr -d '[:space:]')" ;;
    curl)
      local -a auth=()
      [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
      sha="$(curl -sS --max-time 20 \
        -H 'Accept: application/vnd.github.sha' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "${auth[@]}" \
        "https://api.github.com/repos/${repo}/commits/${ref}" 2>/dev/null | tr -d '[:space:]')"
      ;;
  esac

  # Anything that is not exactly 40 hex characters is an error page, a rate
  # limit message or an empty response. Never write one of those into a file.
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || return 1
  SHA_CACHE[$key]="${sha}"
  printf '%s' "${sha}"
}

# ─────────────────────────────────────────────────────────────────────────────
section "pin GitHub Actions to commit SHAs"
detect_resolver
info "${#WORKFLOWS[@]} workflow file(s) in ${WORKFLOW_DIR#"${REPO_ROOT}"/}"
(( DRY_RUN )) && info "dry run — nothing will be written"

TOTAL=0; PINNED=0; ALREADY=0; SKIPPED=0; FAILED=0
CHANGED_FILES=()

for wf in "${WORKFLOWS[@]}"; do
  rel="${wf#"${REPO_ROOT}"/}"
  tmp="${wf}.pin.$$"
  changed=0
  : > "${tmp}"

  # read -r with IFS unset preserves leading whitespace, which is load-bearing
  # in YAML. The final `|| [[ -n "$line" ]]` keeps a file with no trailing
  # newline from losing its last line.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^([[:space:]]*-?[[:space:]]*uses:[[:space:]]*[\'\"]?)([A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)@([^[:space:]\'\"#]+)([\'\"]?)(.*)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[2]}"
      ref="${BASH_REMATCH[3]}"
      quote="${BASH_REMATCH[4]}"
      rest="${BASH_REMATCH[5]}"
      TOTAL=$(( TOTAL + 1 ))

      if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        ALREADY=$(( ALREADY + 1 ))
        printf '%s\n' "${line}" >> "${tmp}"
        continue
      fi

      # owner/repo, dropping any sub-path (github/codeql-action/upload-sarif).
      repo="$(printf '%s' "${action}" | cut -d/ -f1,2)"

      if sha="$(resolve "${repo}" "${ref}")"; then
        old_comment="$(printf '%s' "${rest}" | sed -n 's/^[[:space:]]*#[[:space:]]*//p')"
        comment="${ref}"
        [[ -n "${old_comment}" && "${old_comment}" != "${ref}" ]] && comment="${ref} — ${old_comment}"
        newline="${prefix}${action}@${sha}${quote} # ${comment}"
        printf '%s\n' "${newline}" >> "${tmp}"
        PINNED=$(( PINNED + 1 ))
        changed=1
        printf '    %s%-46s%s %s@%s%s\n' \
          "${C_DIM}" "${action}@${ref}" "${C_RESET}" "${C_GREEN}" "${sha:0:12}…" "${C_RESET}" >&2
      else
        FAILED=$(( FAILED + 1 ))
        printf '%s\n' "${line}" >> "${tmp}"
        fail "could not resolve ${action}@${ref}"
        step "GET https://api.github.com/repos/${repo}/commits/${ref} did not return a SHA."
        step "Rate limited, a private repo, or a ref that does not exist."
      fi
      continue
    fi

    # Things that look like `uses:` but are not pinnable.
    if [[ "${line}" =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[\'\"]?(\./|docker://) ]]; then
      SKIPPED=$(( SKIPPED + 1 ))
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${wf}"

  if (( changed )); then
    CHANGED_FILES+=("${rel}")
    if (( DRY_RUN )); then
      printf '\n  %s%s%s — would change:\n' "${C_BOLD}" "${rel}" "${C_RESET}" >&2
      diff -u "${wf}" "${tmp}" | tail -n +3 | grep -E '^[-+]' | sed 's/^/    /' >&2 || true
      rm -f "${tmp}"
    else
      # Preserve the original mode; a workflow file is not executable but the
      # principle costs nothing and a --dir elsewhere might be.
      chmod --reference="${wf}" "${tmp}" 2>/dev/null || true
      mv "${tmp}" "${wf}"
      ok "${rel} rewritten"
    fi
  else
    rm -f "${tmp}"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
summary_reset
summary_add "uses: references found"  "$( (( TOTAL > 0 )) && echo PASS || echo WARN )" "${TOTAL}"
summary_add "already pinned by SHA"   "$( (( ALREADY > 0 )) && echo PASS || echo SKIP )" "${ALREADY}"
summary_add "pinned by this run"      "$( (( PINNED > 0 )) && echo PASS || echo SKIP )" \
  "$( (( DRY_RUN )) && echo "${PINNED} (dry run — not written)" || echo "${PINNED}" )"
summary_add "not pinnable (local/docker)" SKIP "${SKIPPED}"
summary_add "failed to resolve"       "$( (( FAILED > 0 )) && echo FAIL || echo PASS )" "${FAILED}"
summary_print "pin-actions"

if (( FAILED > 0 )); then
  fail "${FAILED} reference(s) could not be resolved — nothing was changed for those"
  step "If this is rate limiting:  export GITHUB_TOKEN=... and re-run."
  exit 1
fi

if (( CHECK )); then
  if (( PINNED > 0 )); then
    fail "${PINNED} action(s) are still pinned by tag"
    step "A tag can be force-pushed over. Run:  make pin-actions"
    exit 1
  fi
  ok "every action is pinned by commit SHA"
  exit 0
fi

if (( DRY_RUN )); then
  if (( PINNED > 0 )); then
    warn "${PINNED} action(s) would be pinned — re-run without --dry-run to apply"
  else
    ok "nothing to do — every action is already pinned by SHA"
  fi
  exit 0
fi

if (( PINNED > 0 )); then
  ok "pinned ${PINNED} action(s) across ${#CHANGED_FILES[@]} file(s)"
  printf '\n  %sNext:%s\n' "${C_BOLD}" "${C_RESET}" >&2
  printf '    git diff .github/workflows/    %s— read it before committing%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '    scripts/validate.sh --only yaml\n' >&2
  printf '\n  %sKeep them current with Dependabot — it understands "sha # tag"%s\n' "${C_DIM}" "${C_RESET}" >&2
  printf '  %sand bumps both halves together:%s\n\n' "${C_DIM}" "${C_RESET}" >&2
  cat <<'EOF' >&2
    # .github/dependabot.yml
    version: 2
    updates:
      - package-ecosystem: github-actions
        directory: /
        schedule: { interval: weekly }

EOF
else
  ok "nothing to do — every action is already pinned by SHA"
fi
exit 0
