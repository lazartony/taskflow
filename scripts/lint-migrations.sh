#!/usr/bin/env bash
#
# lint-migrations.sh — catch the migrations that lock a table in production.
#
# Runs Squawk (https://squawkhq.com) over migrations/*.up.sql through Docker,
# then explains, for each rule that fired, what the pattern actually does to a
# running database. A linter that says "require-concurrent-index-creation" and
# stops has told you a rule name; the point is the mechanism.
#
# WHY SQUAWK AND NOT ATLAS
#   Atlas used to be the obvious choice — `atlas migrate lint` understood
#   golang-migrate's directory layout directly and had a richer analyzer set.
#   In October 2025 Ariga moved Atlas's linting (and schema-diffing) behind
#   the paid tier; the community edition no longer includes it. Squawk is
#   Apache-2.0, needs nothing but the SQL files, and covers the locking rules
#   that matter most. The CI workflow uses sbdchd/squawk-action for the same
#   reason.
#
# ADVISORY BY DEFAULT
#   Squawk reports at Warning level almost everywhere, and .github/workflows/
#   ci.yml runs this step with continue-on-error until Phase 3. This script
#   matches that: warnings are printed and explained but do not fail the run.
#   Pass --strict (or set the CI job's continue-on-error to false) once the
#   schema settles.
#
#   scripts/lint-migrations.sh
#   scripts/lint-migrations.sh --strict
#   scripts/lint-migrations.sh --full          # Squawk's own annotated output
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SQUAWK_IMAGE="${SQUAWK_IMAGE:-ghcr.io/sbdchd/squawk:latest}"
PATTERN='*.up.sql'
PG_VERSION="${SQUAWK_PG_VERSION:-17.0}"
EXCLUDE=""
STRICT=0
FULL=0

usage() {
  cat <<'EOF'
lint-migrations.sh — Squawk over migrations/*.up.sql, with the reasons

USAGE
  scripts/lint-migrations.sh [options]

OPTIONS
  --strict          exit 1 if there is any finding (CI's post-Phase-3 mode)
  --full            also print Squawk's own annotated source output
  --pattern GLOB    which files to lint (default '*.up.sql')
  --exclude RULES   comma-separated rule names to ignore
  --pg-version V    target Postgres version (default 17.0) — rules differ;
                    ADD COLUMN with a constant default stopped rewriting the
                    table in 11, for instance
  -h, --help

WHY *.up.sql ONLY
  Down migrations drop things. Every "this drops a column" rule would fire on
  every line of every down migration, and the noise would bury the up-migration
  findings that can actually take production down. Down migrations are checked
  a different way: scripts/migrate.sh test runs them.

EXIT STATUS
  0  no findings, or findings in the default advisory mode
  1  findings and --strict, or Squawk reported an Error-level violation
  2  bad arguments
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)     STRICT=1; shift ;;
    --full)       FULL=1; shift ;;
    --pattern)    PATTERN="${2:?--pattern needs a glob}"; shift 2 ;;
    --exclude)    EXCLUDE="${2:?--exclude needs rule names}"; shift 2 ;;
    --pg-version) PG_VERSION="${2:?--pg-version needs a version}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

MIGRATIONS_DIR="${REPO_ROOT}/migrations"
[[ -d "${MIGRATIONS_DIR}" ]] || die_hint "no migrations/ directory at ${MIGRATIONS_DIR}" \
  "Nothing to lint. Create one with:  scripts/migrate.sh create <name>"

FILE_COUNT="$(find "${MIGRATIONS_DIR}" -maxdepth 1 -name '*.up.sql' | wc -l | tr -d ' ')"
if [[ "${FILE_COUNT}" == "0" ]]; then
  warn "migrations/ contains no *.up.sql files — nothing to lint"
  exit 0
fi

require_docker
require_jq

ensure_image "${SQUAWK_IMAGE}" || die_hint "could not pull ${SQUAWK_IMAGE}" \
  "Squawk runs in Docker so no local install is needed." \
  "Check network access, or:  docker pull ${SQUAWK_IMAGE}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

squawk() {
  local -a args=(--pg-version "${PG_VERSION}")
  [[ -n "${EXCLUDE}" ]] && args+=(--exclude "${EXCLUDE}")
  docker run --rm -v "${MIGRATIONS_DIR}:/migrations:ro" -w /migrations \
    "${SQUAWK_IMAGE}" "${args[@]}" "$@" "${PATTERN}"
}

section "migration lint"
info "${FILE_COUNT} up-migration file(s), Squawk against Postgres ${PG_VERSION}"

if ! squawk --reporter=json > "${TMP}/findings.json" 2>"${TMP}/err.log"; then
  # Squawk exits non-zero when it finds things; only treat unparseable output
  # as a tool failure.
  if ! jq -e 'type == "array"' "${TMP}/findings.json" >/dev/null 2>&1; then
    fail "Squawk did not produce usable output"
    [[ -s "${TMP}/err.log" ]] && sed 's/^/        /' "${TMP}/err.log" >&2
    exit 1
  fi
fi

TOTAL="$(jq 'length' "${TMP}/findings.json")"
ERRORS="$(jq '[.[] | select(.level == "Error")] | length' "${TMP}/findings.json")"

if [[ "${TOTAL}" == "0" ]]; then
  ok "no findings — every up migration is safe to run against a live table"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# What each rule means when the table has 50 million rows and traffic on it
# ─────────────────────────────────────────────────────────────────────────────
#
# Every entry answers the same question: what does a user of this service
# experience while this statement runs? "Blocks writes" is the answer that
# matters, and it is never in the rule name.
explain_rule() {
  case "$1" in
    require-concurrent-index-creation)
      cat <<'T'
CREATE INDEX without CONCURRENTLY takes a SHARE lock on the table and holds
it for the entire build. Every INSERT, UPDATE and DELETE on that table blocks
until it finishes — minutes on a large table. The writes do not fail, they
queue: connections pile up, the pool saturates, and requests that never touch
this table start timing out too.
  Fix: CREATE INDEX CONCURRENTLY. It cannot run inside a transaction, and
  golang-migrate wraps each file in one, so it needs a file of its own.
  It can also leave an INVALID index behind if it fails — check for those.
T
      ;;
    require-lock-timeout)
      cat <<'T'
Without lock_timeout the migration waits indefinitely for its lock. That is
bad on its own, but the real damage is what queues behind it: a DDL statement
waiting for an ACCESS EXCLUSIVE lock blocks every query that arrives after it,
including plain SELECTs. One patient migration takes the table down.
  Fix: SET lock_timeout = '1s'; before the statement, so it gives up quickly
  and you retry, rather than silently becoming an outage.
T
      ;;
    require-statement-timeout)
      cat <<'T'
Nothing bounds how long the statement itself may run once it has its lock. A
migration you expected to take two seconds and which takes forty minutes is
indistinguishable from a hung one, and you will not know whether cancelling it
is safe.
  Fix: SET statement_timeout = '5s'; (or whatever you have actually measured
  against a production-sized copy).
T
      ;;
    prefer-robust-stmts)
      cat <<'T'
No IF NOT EXISTS / IF EXISTS. If the migration fails part-way, golang-migrate
marks the schema dirty and the retry fails immediately on the first statement,
which has already been applied. You then have to reconcile the schema by hand
and `migrate force` it — at whatever time of night this happened.
  Fix: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, DROP ... IF
  EXISTS, so re-running the file is a no-op rather than an error.
T
      ;;
    prefer-text-field)
      cat <<'T'
varchar(n) bakes the length limit into the column type. Changing n later needs
ALTER COLUMN TYPE, which takes an ACCESS EXCLUSIVE lock and blocks reads AND
writes while it rewrites the table. Postgres stores text and varchar
identically — the limit buys nothing at runtime.
  Fix: TEXT plus a CHECK constraint. The check can be added NOT VALID and
  validated afterwards without an exclusive lock, so the limit stays adjustable.
T
      ;;
    prefer-bigint-over-int|prefer-big-int|prefer-bigint-over-smallint)
      cat <<'T'
A 32-bit integer key runs out at 2,147,483,647. Migrating a busy int column to
bigint rewrites the entire table under an ACCESS EXCLUSIVE lock and doubles its
size in the process. This is free to prevent today and extremely expensive to
fix on the day the sequence overflows — which is always a day when the table is
already the busiest thing you own.
  Fix: bigint (or bigserial / GENERATED ALWAYS AS IDENTITY) from the start.
T
      ;;
    adding-field-with-default)
      cat <<'T'
ADD COLUMN ... DEFAULT. Since Postgres 11 a CONSTANT default is metadata-only
and fast. A VOLATILE default — now(), gen_random_uuid(), random() — still
rewrites every row of the table while holding ACCESS EXCLUSIVE, blocking reads
and writes for the duration.
  Fix: add the column with no default, backfill in batches, then set the
  default for new rows.
T
      ;;
    adding-foreign-key-constraint|constraint-missing-not-valid)
      cat <<'T'
ADD CONSTRAINT validates every existing row before it returns, holding a lock
on BOTH tables while it does. On a large child table that is a full scan with
writes blocked at each end.
  Fix: two steps. ADD CONSTRAINT ... NOT VALID (instant, applies to new rows),
  then VALIDATE CONSTRAINT in a separate migration — validation takes only a
  SHARE UPDATE EXCLUSIVE lock, which does not block writes.
T
      ;;
    adding-not-nullable-field|adding-required-field)
      cat <<'T'
Adding a NOT NULL column with no default to a table that already has rows fails
outright. Adding one with a default rewrites the table. Either way this is not
a migration you can run on a live table without noticing.
  Fix: add it nullable, backfill in batches, add a CHECK (col IS NOT NULL)
  NOT VALID, validate it, then SET NOT NULL — which can use the validated
  check instead of re-scanning (Postgres 12+).
T
      ;;
    disallowed-unique-constraint)
      cat <<'T'
ALTER TABLE ... ADD CONSTRAINT ... UNIQUE builds the backing index while
holding ACCESS EXCLUSIVE — reads and writes both blocked for the whole build.
  Fix: CREATE UNIQUE INDEX CONCURRENTLY first, then
  ALTER TABLE ... ADD CONSTRAINT ... UNIQUE USING INDEX, which is instant.
T
      ;;
    changing-column-type)
      cat <<'T'
ALTER COLUMN TYPE rewrites the table under ACCESS EXCLUSIVE and invalidates
every dependent view, index and stored plan. It also breaks any deployed code
that assumed the old type, and during a rolling deploy the old code is still
running.
  Fix: add a new column, dual-write, backfill, switch reads, drop the old one
  in a later release.
T
      ;;
    ban-drop-column|ban-drop-table|ban-drop-not-null|ban-drop-database)
      cat <<'T'
The drop is instant in the database and fatal to whatever is still deployed and
still referencing it. During a rolling deploy the old and new versions run at
the same time by design, so "the new code does not use it" is not enough.
  Fix: ship the code that stops using it, wait for the rollout to complete,
  drop it in the next release. Two deploys, no incident.
T
      ;;
    renaming-column|renaming-table)
      cat <<'T'
A rename is not backwards compatible for even one second — every running
instance breaks the moment it commits, and rolling back the code does not undo
it.
  Fix: add the new name, write to both, migrate readers, drop the old name
  later. Never rename in place on a live system.
T
      ;;
    ban-char-field)
      cat <<'T'
char(n) blank-pads to n characters and compares with those pads, which produces
comparisons and lengths nobody expects. It also has the varchar(n) problem:
changing n rewrites the table.
T
      ;;
    prefer-identity)
      cat <<'T'
serial is a Postgres-ism: an integer column plus a separately-owned sequence
whose ownership and permissions have to be managed by hand and which pg_dump
handles awkwardly.
  Fix: GENERATED ALWAYS AS IDENTITY — standard SQL, no orphan sequence.
T
      ;;
    prefer-timestamptz)
      cat <<'T'
timestamp without time zone stores a wall-clock reading with no offset. Every
process that reads it applies its own idea of the time zone, so the value means
something different in the app, in psql and in a report. There is no migration
that recovers the intent afterwards.
  Fix: timestamptz. It stores an absolute instant.
T
      ;;
    ban-concurrent-index-creation-in-transaction|transaction-nesting)
      cat <<'T'
CREATE INDEX CONCURRENTLY cannot run inside a transaction block, and
golang-migrate wraps each migration file in one.
  Fix: put the concurrent index in its own file and mark it as running outside
  a transaction, or apply it out of band and `migrate force` the version.
T
      ;;
    adding-serial-primary-key-field)
      cat <<'T'
Adding a serial primary key to an existing table rewrites it and builds the
unique index under an exclusive lock.
T
      ;;
    *)
      printf 'No local explanation for this rule. See https://squawkhq.com/docs/%s\n' "$1"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────────────────
printf '\n' >&2
if (( ERRORS > 0 )); then
  fail "${TOTAL} finding(s), ${ERRORS} at Error level"
else
  warn "${TOTAL} finding(s), all at Warning level"
fi

jq -r '[.[] | .rule_name] | group_by(.) | map({rule: .[0], n: length})
       | sort_by(-.n)[] | "\(.n)\t\(.rule)"' "${TMP}/findings.json" > "${TMP}/rules.tsv"

while IFS=$'\t' read -r count rule; do
  [[ -z "${rule}" ]] && continue
  printf '\n  %s%s%s  %s(%s occurrence%s)%s\n' \
    "${C_BOLD}" "${rule}" "${C_RESET}" "${C_DIM}" "${count}" \
    "$( (( count == 1 )) && echo "" || echo "s")" "${C_RESET}" >&2

  # Where, at most six, so one noisy rule cannot bury the others.
  # Dedupe and sort as (file, line) objects: sorting the "file:line" STRINGS
  # would put line 58 before line 6.
  jq -r --arg r "${rule}" '
    [.[] | select(.rule_name == $r) | {f: .file, l: .line}] | unique
    | .[0:6] | map("\(.f):\(.l)") | join("  ")
  ' "${TMP}/findings.json" | sed 's/^/    /' >&2
  sites="$(jq -r --arg r "${rule}" \
    '[.[] | select(.rule_name == $r) | {f: .file, l: .line}] | unique | length' \
    "${TMP}/findings.json")"
  if (( sites > 6 )); then
    printf '    %s… and %d more%s\n' "${C_DIM}" "$(( sites - 6 ))" "${C_RESET}" >&2
  fi
  printf '\n' >&2
  explain_rule "${rule}" | sed 's/^/    /' >&2
done < "${TMP}/rules.tsv"

if (( FULL )); then
  section "Squawk's annotated output"
  squawk --reporter=tty 2>&1 | sed 's/^/  /' >&2 || true
fi

# ─────────────────────────────────────────────────────────────────────────────
summary_reset
while IFS=$'\t' read -r count rule; do
  [[ -z "${rule}" ]] && continue
  summary_add "${rule}" WARN "${count} occurrence(s)"
done < "${TMP}/rules.tsv"
summary_print "migration lint"

printf '  %sTo silence a rule you have decided about:  --exclude %s%s\n' \
  "${C_DIM}" "$(head -1 "${TMP}/rules.tsv" | cut -f2)" "${C_RESET}" >&2
printf '  %sTo see the offending SQL in context:       --full%s\n\n' "${C_DIM}" "${C_RESET}" >&2

if (( ERRORS > 0 )); then
  fail "Error-level findings must be fixed"
  exit 1
fi
if (( STRICT )); then
  fail "--strict: ${TOTAL} finding(s)"
  exit 1
fi
warn "advisory — nothing failed. Run with --strict once the schema settles,"
step "and flip continue-on-error to false on the CI job at the same time."
exit 0
