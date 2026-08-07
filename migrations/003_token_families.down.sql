DROP INDEX IF EXISTS idx_refresh_tokens_valid;
DROP INDEX IF EXISTS idx_refresh_tokens_family;
ALTER TABLE refresh_tokens
    DROP COLUMN IF EXISTS used_at,
    DROP COLUMN IF EXISTS parent_id,
    DROP COLUMN IF EXISTS family_id;
