-- Runs once, on first container start, before migrations.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
