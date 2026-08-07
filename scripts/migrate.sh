#!/usr/bin/env bash
#
# migrate.sh — golang-migrate, through Docker, so nothing has to be installed.
#
# The interesting subcommand is `test`. Everything else is a thin wrapper.
#
#   up → pg_dump → down -all → up → pg_dump → diff
#
# Down migrations are broken in most real repositories, and they are broken in
# a specific way: nobody runs them until the night a deploy has to be rolled
# back, at which point the rollback fails too and the incident doubles in
# length. They rot silently because `up` is exercised by every developer on
# every branch and `down` is exercised by nobody.
#
# `test` runs the cycle against a THROWAWAY database, never your dev data — a
# down-migration test that eats the database you were working in would be
# learned once and then never run again, which defeats the point.
#
#   scripts/migrate.sh up
#   scripts/migrate.sh down 1
#   scripts/migrate.sh status
#   scripts/migrate.sh test
#   scripts/migrate.sh create add_task_labels
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MIGRATE_IMAGE="${MIGRATE_IMAGE:-migrate/migrate:v4.19.1}"
PG_IMAGE="${PG_IMAGE:-postgres:17-alpine}"
MIGRATIONS_DIR="${REPO_ROOT}/migrations"
TEST_DB="${MIGRATE_TEST_DB:-taskflow_migrate_test}"
URL_OVERRIDE=""
KEEP_TEST_DB=0

usage() {
  cat <<'EOF'
migrate.sh — schema migrations for TaskFlow (golang-migrate via Docker)

USAGE
  scripts/migrate.sh <command> [args] [options]

COMMANDS
  up [N]            apply all pending migrations, or the next N
  down N            roll back N migrations. N is required — there is no
                    "probably you meant one" for destructive DDL
  down all          roll back everything
  status            current version, dirty flag, and which files are pending
  force V           mark the schema as being at version V without running
                    anything. The escape hatch for a dirty state; read
                    `status` first and know why it is dirty
  create <name>     write a timestamped .up.sql / .down.sql pair
  test              up → dump → down all → up → dump → diff, on a throwaway
                    database. Fails if the two schemas differ, or if `down`
                    leaves objects behind

OPTIONS
  --url URL         database URL (default: DATABASE_URL from .env, else the
                    compose dev database on localhost:5432)
  --test-db NAME    scratch database name for `test` (default taskflow_migrate_test)
  --keep-test-db    do not drop the scratch database afterwards
  -h, --help

DATABASE URL RESOLUTION
  1. --url
  2. DATABASE_URL in .env
  3. postgresql://postgres:password@localhost:5432/taskflow_dev

  sslmode=disable is appended when the URL has no query string, because the
  compose Postgres does not serve TLS and golang-migrate's default is prefer.

EXAMPLES
  scripts/migrate.sh up
  scripts/migrate.sh down 1
  scripts/migrate.sh test
  scripts/migrate.sh create add_task_labels
  scripts/migrate.sh status --url postgres://user:pw@db.internal:5432/app
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { usage; exit 2; }

CMD=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)          URL_OVERRIDE="${2:?--url needs a value}"; shift 2 ;;
    --test-db)      TEST_DB="${2:?--test-db needs a value}"; shift 2 ;;
    --keep-test-db) KEEP_TEST_DB=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             fail "unknown option: $1"; echo; usage; exit 2 ;;
    *)              if [[ -z "${CMD}" ]]; then CMD="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

[[ -n "${CMD}" ]] || { fail "no command given"; echo; usage; exit 2; }

case "${CMD}" in
  up|down|status|force|create|test) ;;
  *) fail "unknown command: ${CMD}"; echo; usage; exit 2 ;;
esac

# create needs no database and no Docker daemon; everything else does.
if [[ "${CMD}" != "create" ]]; then
  require_docker
fi

# ─────────────────────────────────────────────────────────────────────────────
# Database URL
# ─────────────────────────────────────────────────────────────────────────────
resolve_url() {
  local u=""
  if [[ -n "${URL_OVERRIDE}" ]]; then
    u="${URL_OVERRIDE}"
  else
    u="$(env_file_value DATABASE_URL 2>/dev/null || true)"
    [[ -z "${u}" ]] && u="${DATABASE_URL}"
  fi
  # A URL copied out of docker-compose.yml points at the compose-internal
  # hostname. From the host that name does not resolve, and the resulting
  # "dial tcp: lookup postgres" is not an obvious message.
  if [[ "${u}" == *"@postgres:"* ]]; then
    warn "DATABASE_URL points at the compose-internal host 'postgres'"
    step "Rewriting to localhost — that is the same database, reached from the host."
    u="${u/@postgres:/@localhost:}"
  fi
  [[ "${u}" == *"?"* ]] || u="${u}?sslmode=disable"
  printf '%s' "${u}"
}

DB_URL="$(resolve_url)"

url_part() { # url, part = host|port|db
  local u="$1" rest
  rest="${u#*://}"; rest="${rest#*@}"
  case "$2" in
    host) printf '%s' "${rest%%[:/?]*}" ;;
    port) local hp="${rest%%[/?]*}"; [[ "${hp}" == *:* ]] && printf '%s' "${hp##*:}" || printf '5432' ;;
    db)   local p="${rest#*/}"; printf '%s' "${p%%\?*}" ;;
  esac
}

DB_HOST="$(url_part "${DB_URL}" host)"
DB_NAME="$(url_part "${DB_URL}" db)"

# Same URL with a different database name — used to reach the maintenance
# database so `test` can CREATE/DROP its scratch database.
url_with_db() {
  local u="$1" newdb="$2" head tail_q
  head="${u%%\?*}"
  tail_q=""
  [[ "${u}" == *"?"* ]] && tail_q="?${u#*\?}"
  printf '%s/%s%s' "${head%/*}" "${newdb}" "${tail_q}"
}

# ─────────────────────────────────────────────────────────────────────────────
# How a container reaches that database
# ─────────────────────────────────────────────────────────────────────────────
#
# The URL is written from the host's point of view. Inside a container,
# "localhost" is the container. Two ways out:
#
#   Linux  --network host           — the container shares the host's stack
#   else   host.docker.internal     — Docker Desktop's name for the host,
#                                     which needs --add-host on Linux and is
#                                     built in elsewhere
NET_ARGS=()
CONTAINER_URL="${DB_URL}"

compute_net_args() {
  local ostype
  ostype="$(docker info --format '{{.OSType}}' 2>/dev/null || echo linux)"
  if [[ "${DB_HOST}" == "localhost" || "${DB_HOST}" == "127.0.0.1" || "${DB_HOST}" == "0.0.0.0" ]]; then
    if [[ "${ostype}" == "linux" ]]; then
      NET_ARGS=(--network host)
    else
      NET_ARGS=(--add-host "host.docker.internal:host-gateway")
      CONTAINER_URL="${DB_URL/${DB_HOST}/host.docker.internal}"
    fi
  elif docker network inspect taskflow >/dev/null 2>&1; then
    # A non-local host that happens to be a compose service name.
    NET_ARGS=(--network taskflow)
  else
    NET_ARGS=()
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Running the tools
# ─────────────────────────────────────────────────────────────────────────────
migrate_cli() { # <database-url> <migrate args...>
  local url="$1"; shift
  docker run --rm "${NET_ARGS[@]}" \
    -v "${MIGRATIONS_DIR}:/migrations:ro" \
    "${MIGRATE_IMAGE}" \
    -path=/migrations -database "${url}" "$@"
}

# The same URL as a container would have to write it — only different in the
# non-Linux case, where the host is reached as host.docker.internal.
to_container_url() {
  [[ "${CONTAINER_URL}" == "${DB_URL}" ]] && { printf '%s' "$1"; return; }
  printf '%s' "${1/${DB_HOST}/$(url_part "${CONTAINER_URL}" host)}"
}

# psql: any reasonably recent client can query any server, so a local binary is
# fine when there is one.
pg_psql() { # <url> <args...>
  local url="$1"; shift
  if command -v psql >/dev/null 2>&1; then
    psql "${url}" "$@"
  else
    docker run --rm -i "${NET_ARGS[@]}" "${PG_IMAGE}" psql "$(to_container_url "${url}")" "$@"
  fi
}

pg_q() { # <url> <sql>  → tuples only
  pg_psql "$1" -v ON_ERROR_STOP=1 -tAX -c "$2"
}

PG_SERVER_MAJOR=""
server_major() {
  [[ -n "${PG_SERVER_MAJOR}" ]] && { printf '%s' "${PG_SERVER_MAJOR}"; return; }
  local n
  n="$(pg_q "$1" 'SHOW server_version_num' 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${n}" =~ ^[0-9]+$ ]]; then PG_SERVER_MAJOR=$(( n / 10000 )); else PG_SERVER_MAJOR=17; fi
  printf '%s' "${PG_SERVER_MAJOR}"
}

# pg_dump, unlike psql, hard-refuses to dump a server newer than itself:
#
#   pg_dump: error: aborting because of server version mismatch
#
# Ubuntu 24.04 ships pg_dump 16 and the compose database is 17, so "use the
# local binary if it exists" is exactly wrong here. Match the server instead —
# through a container, which is free and always the right version.
pg_dump_schema() { # <url> <out-file>
  local url="$1" out="$2" major local_major img
  major="$(server_major "${url}")"
  if command -v pg_dump >/dev/null 2>&1; then
    # "pg_dump (PostgreSQL) 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)" → 16.
    # Do not regex over the whole line: the Ubuntu suffix contains "24.04".
    local_major="$(pg_dump --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)"
    if [[ "${local_major}" == "${major}" ]]; then
      pg_dump --schema-only --no-owner --no-privileges "${url}" > "${out}"
      return
    fi
    step "local pg_dump is ${local_major:-unknown}, server is ${major} — using postgres:${major}-alpine"
  fi
  img="postgres:${major}-alpine"
  ensure_image "${img}" || die_hint "could not pull ${img}" \
    "pg_dump must match the server major version (${major})." \
    "Either allow the pull, or install postgresql-client-${major} locally."
  docker run --rm "${NET_ARGS[@]}" "${img}" \
    pg_dump --schema-only --no-owner --no-privileges "$(to_container_url "${url}")" > "${out}"
}

preflight_db() {
  compute_net_args
  ensure_image "${MIGRATE_IMAGE}" || die_hint "could not pull ${MIGRATE_IMAGE}" \
    "Migrations run through Docker so no local golang-migrate is needed." \
    "Check network access, or docker pull ${MIGRATE_IMAGE} by hand."
  if ! pg_q "${DB_URL}" 'SELECT 1' >/dev/null 2>&1; then
    if container_exists "${PG_CONTAINER}" && ! container_running "${PG_CONTAINER}"; then
      die_hint "postgres is not running (container ${PG_CONTAINER} exists but is stopped)" \
        "Try:  make up"
    fi
    die_hint "cannot connect to ${DB_HOST}/${DB_NAME}" \
      "URL:  ${DB_URL%%\?*}" \
      "If this is the compose database, start it:  make up" \
      "If it is somewhere else, pass it explicitly:  scripts/migrate.sh ${CMD} --url ..."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Migration files on disk
# ─────────────────────────────────────────────────────────────────────────────
# One helper, because `find -printf` is GNU-only. BSD find (macOS) rejects it,
# and with stderr swallowed the three call sites below used to report "no
# migrations" on every Mac rather than failing loudly — the worst kind of
# portability bug. `-exec basename` is in POSIX and behaves the same on both.
migration_files() { # [glob]  → bare filenames, one per line
  find "${MIGRATIONS_DIR}" -maxdepth 1 -name "${1:-*.up.sql}" \
    -exec basename {} \; 2>/dev/null || true
}

migration_versions() {
  migration_files \
    | sed -E 's/^([0-9]+)_.*/\1/' | grep -E '^[0-9]+$' | sort -n || true
}

migration_name_for() {
  migration_files "${1}_*.up.sql" \
    | head -1 | sed -E "s/^${1}_//; s/\.up\.sql$//"
}

check_pairs() {
  local missing=0 f base
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    base="${f%.up.sql}"
    if [[ ! -f "${MIGRATIONS_DIR}/${base}.down.sql" ]]; then
      fail "${base}.up.sql has no matching ${base}.down.sql"
      missing=1
    fi
  done < <(migration_files | sort)
  return "${missing}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────
cmd_up() {
  preflight_db
  local n="${ARGS[0]:-}"
  section "migrate up"
  if [[ -n "${n}" ]]; then
    [[ "${n}" =~ ^[0-9]+$ ]] || die "up takes a number of steps, got '${n}'"
    info "applying the next ${n} migration(s) to ${DB_NAME}"
    migrate_cli "${CONTAINER_URL}" up "${n}"
  else
    info "applying all pending migrations to ${DB_NAME}"
    migrate_cli "${CONTAINER_URL}" up
  fi
  ok "schema is at version $(current_version)"
}

cmd_down() {
  preflight_db
  local n="${ARGS[0]:-}"
  [[ -n "${n}" ]] || {
    fail "down needs a number of steps: scripts/migrate.sh down 1"
    step "or 'down all' to roll everything back. There is no default, because"
    step "the default would eventually be wrong at three in the morning."
    exit 2
  }
  section "migrate down"
  if [[ "${n}" == "all" || "${n}" == "-all" ]]; then
    warn "rolling back EVERY migration on ${DB_NAME} at ${DB_HOST}"
    migrate_cli "${CONTAINER_URL}" down -all
  else
    [[ "${n}" =~ ^[0-9]+$ ]] || die "down takes a number of steps or 'all', got '${n}'"
    info "rolling back ${n} migration(s) on ${DB_NAME}"
    # -all is the only unattended form; the numeric form prompts unless told.
    printf 'y\n' | migrate_cli "${CONTAINER_URL}" down "${n}"
  fi
  ok "schema is at version $(current_version)"
}

current_version() {
  local v
  v="$(pg_q "${DB_URL}" \
    "SELECT version || (CASE WHEN dirty THEN ' (DIRTY)' ELSE '' END)
     FROM schema_migrations LIMIT 1" 2>/dev/null | tr -d '[:space:]')" || true
  printf '%s' "${v:-none}"
}

cmd_status() {
  preflight_db
  section "migration status"

  local applied_to dirty
  applied_to="$(pg_q "${DB_URL}" 'SELECT version FROM schema_migrations LIMIT 1' 2>/dev/null | tr -d '[:space:]' || true)"
  dirty="$(pg_q "${DB_URL}" 'SELECT dirty FROM schema_migrations LIMIT 1' 2>/dev/null | tr -d '[:space:]' || true)"

  info "database  ${DB_NAME} @ ${DB_HOST}"
  if [[ -z "${applied_to}" ]]; then
    info "version   none — schema_migrations is empty or absent"
  else
    info "version   ${applied_to}"
  fi

  if [[ "${dirty}" == "t" ]]; then
    fail "the schema is DIRTY at version ${applied_to}"
    step "A migration failed part-way. golang-migrate refuses to continue until"
    step "you tell it what the truth is."
    step "  1. Inspect the database and finish or undo version ${applied_to} by hand."
    step "  2. scripts/migrate.sh force $(( applied_to - 1 ))   (if you undid it)"
    step "     scripts/migrate.sh force ${applied_to}           (if you finished it)"
  fi

  printf '\n  %s%-16s %-32s %s%s\n' "${C_DIM}" "version" "name" "state" "${C_RESET}" >&2
  local v name state colour
  while IFS= read -r v; do
    [[ -z "${v}" ]] && continue
    name="$(migration_name_for "${v}")"
    if [[ -n "${applied_to}" ]] && (( 10#${v} <= 10#${applied_to} )); then
      state="applied"; colour="${C_GREEN}"
    else
      state="pending"; colour="${C_YELLOW}"
    fi
    printf '  %-16s %-32s %s\n' "${v}" "${name}" "$(cell "${state}" 8 "${colour}")" >&2
  done < <(migration_versions)
  printf '\n' >&2

  check_pairs || warn "some migrations cannot be rolled back at all"
}

cmd_force() {
  preflight_db
  local v="${ARGS[0]:-}"
  [[ "${v}" =~ ^-?[0-9]+$ ]] || { fail "force needs a version number"; exit 2; }
  section "migrate force ${v}"
  warn "this changes the recorded version WITHOUT running any SQL"
  step "Only correct if you have already made the schema match version ${v} by hand."
  migrate_cli "${CONTAINER_URL}" force "${v}"
  ok "schema_migrations now says version $(current_version)"
}

cmd_create() {
  local raw="${ARGS[0]:-}"
  [[ -n "${raw}" ]] || { fail "create needs a name: scripts/migrate.sh create add_task_labels"; exit 2; }
  local name
  name="$(printf '%s' "${raw}" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_-')"
  [[ -n "${name}" ]] || die "'${raw}' contains no usable characters for a filename"

  # Timestamped, not sequential. Two people creating a migration on two
  # branches on the same day get different versions and merge cleanly;
  # sequential numbering gives them both 004 and a conflict that is easy to
  # resolve wrongly. Mixing with the existing 001/002/003 files is fine —
  # golang-migrate only cares that the versions are increasing integers.
  local ts version up down
  ts="$(date -u +%Y%m%d%H%M%S)"
  version="${ts}"
  up="${MIGRATIONS_DIR}/${version}_${name}.up.sql"
  down="${MIGRATIONS_DIR}/${version}_${name}.down.sql"

  [[ -e "${up}" ]] && die "${up} already exists"
  mkdir -p "${MIGRATIONS_DIR}"

  cat > "${up}" <<EOF
-- ${version}_${name}.up.sql
--
-- Safety checklist (scripts/lint-migrations.sh enforces most of it):
--   • CREATE INDEX CONCURRENTLY — a plain CREATE INDEX holds a lock that
--     blocks every write to the table until it finishes.
--   • CONCURRENTLY cannot run inside a transaction. golang-migrate wraps each
--     file in one, so a concurrent index needs its own file with
--     -- migrate:no-transaction, or has to be applied out of band.
--   • Adding a NOT NULL column with a volatile default rewrites the table.
--   • ADD CONSTRAINT ... NOT VALID first, VALIDATE CONSTRAINT second: the
--     one-step form scans the whole table under an exclusive lock.
--   • Dropping a column breaks any deployed code still selecting it. Ship the
--     code that stops using it first.

EOF

  cat > "${down}" <<EOF
-- ${version}_${name}.down.sql
--
-- This file is not decoration. scripts/migrate.sh test applies every up, then
-- every down, then every up again, and fails if the schema differs or if this
-- file leaves anything behind. Write it now, while you still remember what the
-- up migration did.
--
-- Undo everything ${version}_${name}.up.sql created, in reverse order.

EOF

  ok "created migrations/${version}_${name}.up.sql"
  ok "created migrations/${version}_${name}.down.sql"
  step "Then verify the pair:  scripts/migrate.sh test"
}

# ─────────────────────────────────────────────────────────────────────────────
# test — the reason this script exists
# ─────────────────────────────────────────────────────────────────────────────
#
# Normalising the dump is not cosmetic. pg_dump writes its own version and the
# server version into comments, and PostgreSQL 17.6+ emits \restrict with a
# random token on every dump. Comparing raw dumps would fail every single time
# for reasons that have nothing to do with the migrations.
normalise_dump() {
  grep -v -e '^--' -e '^\\restrict' -e '^\\unrestrict' -e '^$' "$1" || true
}

# Script-scope, not local: the EXIT trap that drops the scratch database runs
# after cmd_test has returned, so a `local` here would be gone by then and the
# trap would fail with "unbound variable" instead of cleaning up.
ADMIN_URL=""
TEST_URL=""

cleanup_testdb() {
  [[ -n "${ADMIN_URL}" ]] || return 0
  if (( KEEP_TEST_DB )); then step "keeping ${TEST_DB} (--keep-test-db)"; return 0; fi
  pg_q "${ADMIN_URL}" "DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)" >/dev/null 2>&1 || true
}

cmd_test() {
  compute_net_args
  ensure_image "${MIGRATE_IMAGE}" || die "could not pull ${MIGRATE_IMAGE}"

  section "migration round-trip test"

  check_pairs || die_hint "every up migration needs a down migration" \
    "Without one, this test cannot run and neither can a rollback."

  ADMIN_URL="$(url_with_db "${DB_URL}" postgres)"
  TEST_URL="$(url_with_db "${DB_URL}" "${TEST_DB}")"
  local admin_url="${ADMIN_URL}" test_url="${TEST_URL}"

  if ! pg_q "${admin_url}" 'SELECT 1' >/dev/null 2>&1; then
    if container_exists "${PG_CONTAINER}" && ! container_running "${PG_CONTAINER}"; then
      die_hint "postgres is not running — try: make up"
    fi
    die_hint "cannot reach the Postgres server at ${DB_HOST}" \
      "The test needs the 'postgres' maintenance database to create a scratch one." \
      "Start the stack:  make up"
  fi

  info "scratch database  ${TEST_DB} @ ${DB_HOST}"
  info "your ${DB_NAME} database is not touched"

  trap cleanup_testdb EXIT

  step "recreating ${TEST_DB}"
  pg_q "${admin_url}" "DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE)" >/dev/null
  pg_q "${admin_url}" "CREATE DATABASE ${TEST_DB}" >/dev/null

  local tmp; tmp="$(mktemp -d)"
  local container_test_url="${test_url}"
  if [[ "${CONTAINER_URL}" != "${DB_URL}" ]]; then
    container_test_url="${test_url/${DB_HOST}/$(url_part "${CONTAINER_URL}" host)}"
  fi

  # ── 1. up ──
  step "1/5  applying every up migration"
  migrate_cli "${container_test_url}" up >"${tmp}/up1.log" 2>&1 || {
    cat "${tmp}/up1.log" >&2
    die "the first 'up' failed — fix that before worrying about 'down'"
  }
  pg_dump_schema "${test_url}" "${tmp}/schema-1.sql"
  ok "up applied — $(grep -c '^CREATE TABLE' "${tmp}/schema-1.sql" || true) tables"

  # ── 2. down -all ──
  step "2/5  rolling every migration back"
  if ! migrate_cli "${container_test_url}" down -all >"${tmp}/down.log" 2>&1; then
    cat "${tmp}/down.log" >&2
    fail "a DOWN migration failed"
    step "This is the failure this test exists to find. The rollback path is"
    step "broken NOW, in a scratch database, rather than during an incident."
    exit 1
  fi

  # ── 3. did down actually undo anything? ──
  #
  # A down migration full of no-ops passes an up/down/up diff trivially: the
  # first dump and the second dump are identical because nothing was ever
  # dropped. Checking that the database is empty in between is what makes the
  # test mean something.
  step "3/5  checking the database is actually empty again"
  local residue
  residue="$(pg_q "${test_url}" "
    SELECT string_agg(item, E'\n') FROM (
      SELECT 'table    ' || schemaname || '.' || tablename AS item
        FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')
         AND tablename <> 'schema_migrations'
      UNION ALL
      SELECT 'view     ' || schemaname || '.' || viewname
        FROM pg_views WHERE schemaname NOT IN ('pg_catalog','information_schema')
      UNION ALL
      SELECT 'type     ' || n.nspname || '.' || t.typname
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
          AND t.typtype IN ('e','d','c')
          AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind <> 'c')
      UNION ALL
      SELECT 'function ' || n.nspname || '.' || p.proname
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
    ) s" 2>/dev/null || true)"

  if [[ -n "${residue//[[:space:]]/}" ]]; then
    fail "'down -all' left objects behind"
    printf '%s\n' "${residue}" | sed 's/^/        /' >&2
    step "The down migrations ran without error but did not undo the up"
    step "migrations. A rollback would leave the schema in a state no version"
    step "of the code expects."
    exit 1
  fi
  ok "database is empty — the down migrations really did undo the ups"

  # ── 4. up again ──
  step "4/5  applying every up migration a second time"
  migrate_cli "${container_test_url}" up >"${tmp}/up2.log" 2>&1 || {
    cat "${tmp}/up2.log" >&2
    fail "the SECOND 'up' failed"
    step "The up migrations are not repeatable after a rollback — usually a"
    step "down migration that dropped a table but left its type, sequence or"
    step "extension in place."
    exit 1
  }
  pg_dump_schema "${test_url}" "${tmp}/schema-2.sql"

  # ── 5. diff ──
  step "5/5  comparing the two schemas"
  normalise_dump "${tmp}/schema-1.sql" > "${tmp}/n1.sql"
  normalise_dump "${tmp}/schema-2.sql" > "${tmp}/n2.sql"

  if diff -u "${tmp}/n1.sql" "${tmp}/n2.sql" > "${tmp}/schema.diff"; then
    ok "schemas are identical after up → down → up"
    printf '\n'
    info "the rollback path works. Re-run this whenever you add a migration."
    return 0
  fi

  fail "THE SCHEMA CHANGED across an up → down → up cycle"
  printf '\n'
  sed -e 's/^/        /' "${tmp}/schema.diff" >&2
  printf '\n'
  step "Left  = schema after the first up"
  step "Right = schema after down -all and up again"
  step "Lines starting with '-' exist only the first time; '+' only the second."
  step "A rollback followed by a re-deploy would NOT restore the schema you had."
  exit 1
}

case "${CMD}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  force)  cmd_force ;;
  create) cmd_create ;;
  test)   cmd_test ;;
esac
