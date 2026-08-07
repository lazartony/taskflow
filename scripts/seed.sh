#!/usr/bin/env bash
#
# seed.sh — deterministic benchmark fixture generator.
#
# Generates users and tasks with SQL `INSERT ... SELECT generate_series(...)`,
# not through the API. Seeding 1,000,000 tasks over HTTP takes hours and
# measures your own load generator; the same data goes in over SQL in seconds.
#
# DETERMINISM IS THE POINT. Every id, title, status, priority and timestamp is
# derived from the row index via md5 — no random(), no now(). Re-seeding
# produces byte-identical data, so a benchmark run today is comparable with one
# from last month, and the cache-on and cache-off halves of an A/B are reading
# exactly the same rows.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── The seeded password ──────────────────────────────────────────────────────
#
# A precomputed bcrypt hash, so seeded users can actually LOG IN — the load
# suite authenticates like a real client rather than being handed a token by a
# back door. It is precomputed because hashing 10,000 passwords at cost 12 takes
# roughly ten minutes of pure CPU, and repeating that on every seed is absurd.
#
# password : BenchPass123!
# hash     : bcrypt, $2b$ variant, cost 12 (matches BCRYPT_COST=12 in
#            docker-compose.yml — a hash at a different cost still VERIFIES
#            fine, but logins would then measure a different amount of work
#            than production does)
#
# If an implementation's bcrypt library rejects the $2b$ prefix (some very old
# Go x/crypto builds only accept $2a$), change the prefix to $2a$ — the digest
# is identical, only the version marker differs.
SEED_PASSWORD="${SEED_PASSWORD:-BenchPass123!}"
SEED_PASSWORD_HASH="${SEED_PASSWORD_HASH:-\$2b\$12\$Lj01Oe2WQZQWFEttnNJwiu7bBJGzPOlOy0/TyVahOcNVK9yZGnRCi}"

SIZE="small"
TRUNCATE=0
MANIFEST_ONLY=0
MANIFEST_USERS=25
CHUNK=500
QUIET=0

usage() {
  cat <<'EOF'
seed.sh — deterministic benchmark data for TaskFlow

USAGE
  scripts/seed.sh [--size small|large|huge] [options]

SIZES
  --size small     10 users x 20 tasks        =        200 tasks   (default)
  --size large   1000 users x 100 tasks       =    100,000 tasks
  --size huge   10000 users x 100 tasks       =  1,000,000 tasks

  "huge" is the fixture the CI spec's fair-comparison rule 4 calls for
  (10,000 users x 100 tasks). Expect it to take 30-90s and ~600 MB of table
  and index space.

OPTIONS
  --users N               override the user count
  --tasks N               override the tasks-per-user count
  --truncate              DELETE all existing users/tasks first (CASCADE).
                          Required for a repeatable benchmark: appending to a
                          previous seed changes row counts and therefore plans.
  --chunk N               users per INSERT batch (default 500)
  --manifest-users N      how many users to list in the manifest (default 25)
  --manifest-only         rewrite benchmarks/seed-manifest.json, insert nothing
  --database-url URL      override DATABASE_URL (default: the compose dev DB)
  --quiet
  -h, --help

OUTPUT
  benchmarks/seed-manifest.json — credentials and sample task ids, consumed by
  the k6 suite via SEED_MANIFEST=... so every run authenticates as the same
  deterministic user and reads the same rows.

CREDENTIALS
  email    bench-user-<n>@taskflow.test      (n = 1..users)
  password BenchPass123!

EXAMPLES
  scripts/seed.sh --size small --truncate
  scripts/seed.sh --size huge --truncate
  scripts/seed.sh --users 200 --tasks 50 --truncate
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)           SIZE="${2:?--size needs a value}"; shift 2 ;;
    --users)          USERS="${2:?}"; shift 2 ;;
    --tasks)          TASKS="${2:?}"; shift 2 ;;
    --truncate)       TRUNCATE=1; shift ;;
    --chunk)          CHUNK="${2:?}"; shift 2 ;;
    --manifest-users) MANIFEST_USERS="${2:?}"; shift 2 ;;
    --manifest-only)  MANIFEST_ONLY=1; shift ;;
    --database-url)   DATABASE_URL="${2:?}"; export DATABASE_URL; shift 2 ;;
    --quiet)          QUIET=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) fail "unknown argument: $1"; echo; usage; exit 2 ;;
  esac
done

case "${SIZE}" in
  small) USERS="${USERS:-10}";    TASKS="${TASKS:-20}"  ;;
  large) USERS="${USERS:-1000}";  TASKS="${TASKS:-100}" ;;
  huge)  USERS="${USERS:-10000}"; TASKS="${TASKS:-100}" ;;
  *) die "unknown --size '${SIZE}' (expected small, large or huge)" ;;
esac

[[ "${USERS}" =~ ^[0-9]+$ && "${USERS}" -gt 0 ]] || die "--users must be a positive integer"
[[ "${TASKS}" =~ ^[0-9]+$ && "${TASKS}" -gt 0 ]] || die "--tasks must be a positive integer"

TOTAL_TASKS=$(( USERS * TASKS ))
MANIFEST_PATH="${REPO_ROOT}/benchmarks/seed-manifest.json"

section "seed (${SIZE})"
info "${USERS} users x ${TASKS} tasks = ${TOTAL_TASKS} rows"

# ─────────────────────────────────────────────────────────────────────────────
# Manifest — written even when --manifest-only, because it is pure derivation.
# ─────────────────────────────────────────────────────────────────────────────
write_manifest() {
  require_jq
  mkdir -p "$(dirname "${MANIFEST_PATH}")"
  local n=$(( MANIFEST_USERS < USERS ? MANIFEST_USERS : USERS ))
  # `.users` is the array tests/load/lib/auth.js reads: [{index,email,password}].
  # SEED_USER_INDEX picks one, so parallel or repeated runs can target different
  # users without fighting over the same cache keys.
  jq -n \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg size "${SIZE}" \
    --arg password "${SEED_PASSWORD}" \
    --argjson userCount "${USERS}" \
    --argjson tasksPerUser "${TASKS}" \
    --argjson totalTasks "${TOTAL_TASKS}" \
    --argjson listed "${n}" \
    '{
      schema: "taskflow.seed-manifest.v1",
      generatedAt: $generatedAt,
      size: $size,
      userCount: $userCount,
      tasksPerUser: $tasksPerUser,
      totalTasks: $totalTasks,
      password: $password,
      note: "The API exposes tsk_/usr_ prefixed opaque ids while the database stores uuids (docs/openapi.yaml). The mapping is an implementation detail, so the k6 suite discovers task ids at runtime via GET /tasks rather than deriving them here.",
      users: [ range(1; $listed + 1) | {
        index: .,
        email: ("bench-user-" + (.|tostring) + "@taskflow.test"),
        password: $password
      } ]
    }' > "${MANIFEST_PATH}"
  ok "manifest → benchmarks/seed-manifest.json (${n} of ${USERS} users listed)"
}

if (( MANIFEST_ONLY )); then
  write_manifest
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Preconditions
# ─────────────────────────────────────────────────────────────────────────────
detect_psql
step "postgres access: ${PSQL_MODE}"
pg_ready || die_hint "cannot connect to Postgres" \
  "Tried: ${PSQL_MODE} (${DATABASE_URL})" \
  "Start it:   docker compose up -d postgres" \
  "Migrate it: docker compose up migrate"

if ! psql_q "SELECT to_regclass('public.tasks')" | grep -q tasks; then
  die_hint "the 'tasks' table does not exist" \
    "Run the migrations first:  docker compose up migrate" \
    "or:                        scripts/migrate.sh up"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Truncate
# ─────────────────────────────────────────────────────────────────────────────
if (( TRUNCATE )); then
  step "truncating users (CASCADE) — tasks, refresh_tokens and attachments go too"
  psql_q "TRUNCATE users RESTART IDENTITY CASCADE" >/dev/null
  ok "existing data removed"
else
  existing="$(psql_q 'SELECT count(*) FROM users' | tr -d '[:space:]')"
  if [[ "${existing}" != "0" ]]; then
    warn "${existing} users already present and --truncate was not given"
    step "Seeding on top of existing rows changes table statistics and query"
    step "plans, so this run will NOT be comparable with a clean-seeded one."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Insert
# ─────────────────────────────────────────────────────────────────────────────
# Determinism mechanics:
#   id       = md5('taskflow-bench-user-' || i)::uuid   — stable across runs and
#              across machines; md5 of a fixed string is the same everywhere,
#              whereas setseed()+random() depends on the PG version's PRNG.
#   status   = a fixed rotation, so the status distribution is identical every
#              time (filters like ?status=pending must hit the same row counts)
#   times    = derived from the index off a fixed epoch — never now(), because
#              now() makes today's seed differ from yesterday's and quietly
#              changes index selectivity on created_at.
seed_users() {
  local from="$1" to="$2"
  psql_stdin -q <<SQL
INSERT INTO users (id, email, password_hash, display_name, avatar_url, created_at, updated_at)
SELECT
    md5('taskflow-bench-user-' || i)::uuid,
    'bench-user-' || i || '@taskflow.test',
    '${SEED_PASSWORD_HASH}',
    'Bench User ' || i,
    NULL,
    TIMESTAMPTZ '2026-01-01 00:00:00+00' + (i * INTERVAL '17 seconds'),
    TIMESTAMPTZ '2026-01-01 00:00:00+00' + (i * INTERVAL '17 seconds')
FROM generate_series(${from}, ${to}) AS i
ON CONFLICT (id) DO NOTHING;
SQL
}

seed_tasks() {
  local from="$1" to="$2"
  # Field values come from md5 hashes with DIFFERENT SALTS, not from arithmetic
  # on (u, t). An earlier version used (u+t)%4 for status and (u*3+t)%4 for
  # priority; because those two expressions differ by 2u, they share parity and
  # only 8 of the 16 status/priority combinations ever occurred. Composite
  # indexes like idx_tasks_user_status then have unrealistic selectivity and
  # every filtered query is benchmarked against a fixture that cannot happen.
  #
  # ('x'||<7 hex chars>)::bit(28)::int is the standard trick for a deterministic
  # hash-to-integer in Postgres. 28 bits (not 32) so the value is always
  # non-negative and % never returns a negative remainder.
  #
  # Distributions are deliberately skewed towards what a real task app looks
  # like rather than uniform — uniform data makes every filter equally
  # selective, which is the one thing real data never is.
  psql_stdin -q <<SQL
INSERT INTO tasks (id, user_id, title, description, status, priority,
                   due_date, completed_at, created_at, updated_at)
SELECT
    gen.id, gen.user_id, gen.title, gen.description, gen.status, gen.priority,
    gen.due_date,
    -- completedAt is only meaningful for completed rows; the API contract says
    -- so, and a fixture that violates its own invariants will make some
    -- implementation's assertion fire mid-benchmark.
    CASE WHEN gen.status = 'completed' THEN gen.completed_at ELSE NULL END,
    gen.created_at, gen.updated_at
FROM (
  SELECT
    md5('taskflow-bench-task-' || u || '-' || t)::uuid AS id,
    md5('taskflow-bench-user-' || u)::uuid             AS user_id,
    -- Titles vary so the GIN full-text index has something to do and the
    -- ?search= filter is not a no-op.
    'Task ' || t || ' ' ||
      (ARRAY['review','deploy','refactor','document','triage','migrate','profile','benchmark'])[1 + (hw % 8)]
      || ' ' ||
      (ARRAY['api','database','cache','pipeline','schema','index','queue','report'])[1 + (hv % 8)]
      AS title,
    'Deterministic benchmark fixture row for user ' || u || ', task ' || t ||
      '. Padding so the row width is representative rather than trivially small: ' ||
      repeat('x', 40 + (hv % 120)) AS description,
    (CASE WHEN hs <  40 THEN 'pending'
          WHEN hs <  65 THEN 'in_progress'
          WHEN hs <  95 THEN 'completed'
          ELSE               'archived' END)::task_status AS status,
    (CASE WHEN hp <  25 THEN 'low'
          WHEN hp <  65 THEN 'medium'
          WHEN hp <  90 THEN 'high'
          ELSE               'urgent' END)::task_priority AS priority,
    TIMESTAMPTZ '2026-06-01 00:00:00+00' + (hd % 90) * INTERVAL '1 day' AS due_date,
    TIMESTAMPTZ '2026-05-01 00:00:00+00' + (hd % 1400) * INTERVAL '1 hour' AS completed_at,
    TIMESTAMPTZ '2026-02-01 00:00:00+00' + (u * ${TASKS} + t) * INTERVAL '11 seconds' AS created_at,
    TIMESTAMPTZ '2026-02-01 00:00:00+00' + (u * ${TASKS} + t) * INTERVAL '11 seconds' AS updated_at
  FROM generate_series(${from}, ${to}) AS u,
       generate_series(1, ${TASKS})     AS t,
       LATERAL (SELECT
         ('x' || substr(md5('st:' || u || ':' || t), 1, 7))::bit(28)::int % 100 AS hs,
         ('x' || substr(md5('pr:' || u || ':' || t), 1, 7))::bit(28)::int % 100 AS hp,
         ('x' || substr(md5('dd:' || u || ':' || t), 1, 7))::bit(28)::int       AS hd,
         ('x' || substr(md5('w1:' || u || ':' || t), 1, 7))::bit(28)::int       AS hw,
         ('x' || substr(md5('w2:' || u || ':' || t), 1, 7))::bit(28)::int       AS hv
       ) h
) gen
ON CONFLICT (id) DO NOTHING;
SQL
}

started=$(date +%s)
step "inserting users…"
seed_users 1 "${USERS}"

step "inserting tasks in chunks of ${CHUNK} users…"
chunk_start=1
while (( chunk_start <= USERS )); do
  chunk_end=$(( chunk_start + CHUNK - 1 ))
  (( chunk_end > USERS )) && chunk_end="${USERS}"
  seed_tasks "${chunk_start}" "${chunk_end}"
  if (( QUIET == 0 )); then
    pct=$(fpct "${chunk_end}" "${USERS}")
    printf '\r%s   → users %d..%d  (%s%%)%s' "${C_DIM}" "${chunk_start}" "${chunk_end}" "${pct}" "${C_RESET}" >&2
  fi
  chunk_start=$(( chunk_end + 1 ))
done
(( QUIET == 0 )) && printf '\n' >&2

# ANALYZE, always. Without fresh statistics the planner may seq-scan a table it
# should index-scan, and the first benchmark run after a seed would be measuring
# a bad plan rather than the service.
step "ANALYZE (fresh statistics — otherwise the first run measures a stale plan)"
psql_q "ANALYZE users; ANALYZE tasks;" >/dev/null

elapsed=$(( $(date +%s) - started ))

actual_users="$(psql_q 'SELECT count(*) FROM users' | tr -d '[:space:]')"
actual_tasks="$(psql_q 'SELECT count(*) FROM tasks' | tr -d '[:space:]')"
size_pretty="$(psql_q "SELECT pg_size_pretty(pg_total_relation_size('tasks'))" | tr -d '\n')"

ok "seeded in ${elapsed}s — ${actual_users} users, ${actual_tasks} tasks (tasks table: ${size_pretty})"

write_manifest

cat >&2 <<EOF

${C_DIM}Use it:
  export SEED_MANIFEST=benchmarks/seed-manifest.json
  k6 run tests/load/read-heavy.js -e BASE_URL=http://localhost:8001 \\
      -e SEED_MANIFEST=benchmarks/seed-manifest.json

Log in by hand:
  curl -s -X POST http://localhost:8001/api/v1/auth/login \\
    -H 'Content-Type: application/json' \\
    -d '{"email":"bench-user-1@taskflow.test","password":"${SEED_PASSWORD}"}'${C_RESET}
EOF
