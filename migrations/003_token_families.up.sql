-- Phase 7: refresh-token rotation with reuse detection.
-- If a REVOKED token is presented, it was stolen — you can't tell whether the
-- attacker or the legitimate user is holding the copy, so revoke the whole
-- family. This is what OAuth 2.1 mandates for public clients.
ALTER TABLE refresh_tokens
    ADD COLUMN family_id UUID NOT NULL DEFAULT gen_random_uuid(),
    ADD COLUMN parent_id UUID REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    ADD COLUMN used_at   TIMESTAMPTZ;

CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_refresh_tokens_valid  ON refresh_tokens (user_id, token)
    WHERE revoked_at IS NULL AND used_at IS NULL;
