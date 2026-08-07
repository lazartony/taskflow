-- TaskFlow initial schema. Plain SQL, applied by golang-migrate.
-- ONE tool owns this schema — no ORM generates migrations (see docs, C7).

CREATE TYPE task_status   AS ENUM ('pending', 'in_progress', 'completed', 'archived');
CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high', 'urgent');

CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    display_name  VARCHAR(50)  NOT NULL,
    avatar_url    VARCHAR(2048),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at    TIMESTAMPTZ,

    CONSTRAINT users_display_name_length
        CHECK (LENGTH(display_name) >= 2 AND LENGTH(display_name) <= 50),
    CONSTRAINT users_email_format
        CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

CREATE TABLE tasks (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title        VARCHAR(200) NOT NULL,
    description  TEXT,
    status       task_status   NOT NULL DEFAULT 'pending',
    priority     task_priority NOT NULL DEFAULT 'medium',
    due_date     TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ,

    CONSTRAINT tasks_title_length
        CHECK (LENGTH(title) >= 1 AND LENGTH(title) <= 200),
    CONSTRAINT tasks_description_length
        CHECK (description IS NULL OR LENGTH(description) <= 5000)
    -- NOTE: the original schema had CHECK (due_date > NOW()). That is NOT
    -- a valid CHECK constraint — NOW() is not IMMUTABLE, so the row becomes
    -- retroactively invalid as time passes and pg_dump/restore fails on
    -- perfectly good data. "Due date must be in the future" is an
    -- APPLICATION-layer rule (see openapi.yaml). This is a real bug in the
    -- original spec and a good example of why you validate where you can
    -- reason about time.
);

CREATE TABLE refresh_tokens (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token      VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ  NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
    -- Same reasoning: no CHECK (expires_at > NOW()).
);

CREATE TABLE attachments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id    UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    file_name  VARCHAR(255)  NOT NULL,
    file_size  BIGINT        NOT NULL,
    mime_type  VARCHAR(255)  NOT NULL,
    object_key VARCHAR(1024) NOT NULL UNIQUE,
    url        VARCHAR(2048) NOT NULL,
    created_at TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT attachments_file_size
        CHECK (file_size > 0 AND file_size <= 10485760),
    CONSTRAINT attachments_file_name_length
        CHECK (LENGTH(file_name) >= 1 AND LENGTH(file_name) <= 255)
);

-- Indexes
CREATE INDEX idx_users_email      ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_created_at ON users (created_at);

CREATE INDEX idx_tasks_user_id         ON tasks (user_id)               WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_status     ON tasks (user_id, status)       WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_priority   ON tasks (user_id, priority)     WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_due_date   ON tasks (user_id, due_date)     WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_created_at ON tasks (user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_deleted_at      ON tasks (deleted_at);
-- Full-text over title AND description (the API searches both).
CREATE INDEX idx_tasks_search ON tasks
    USING GIN (to_tsvector('english', title || ' ' || COALESCE(description, '')))
    WHERE deleted_at IS NULL;

CREATE INDEX idx_refresh_tokens_user_id    ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_token      ON refresh_tokens (token);
CREATE INDEX idx_refresh_tokens_expires_at ON refresh_tokens (expires_at);

CREATE INDEX idx_attachments_task_id    ON attachments (task_id);
CREATE INDEX idx_attachments_created_at ON attachments (created_at);

-- updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_tasks_updated_at BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
