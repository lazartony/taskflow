-- Phase 6 (outbox/events) + Phase 10 (uploads). Applied from day one so the
-- schema is stable; tables sit empty until you wire them up.

-- Transactional outbox: the event is written in the SAME transaction as the
-- data, then relayed out separately. This is the answer to the dual-write
-- problem. See docs/infrastructure-specification.md §4.5.
CREATE TABLE outbox (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id       UUID         NOT NULL UNIQUE,
    aggregate_type VARCHAR(50)  NOT NULL,
    aggregate_id   UUID         NOT NULL,
    event_type     VARCHAR(100) NOT NULL,
    event_version  VARCHAR(10)  NOT NULL DEFAULT '1.0',
    partition_key  VARCHAR(255) NOT NULL,
    payload        JSONB        NOT NULL,
    headers        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    published_at   TIMESTAMPTZ,
    attempts       INT          NOT NULL DEFAULT 0,
    last_error     TEXT
);
-- Partial index: the relay only scans unpublished rows, so this stays small
-- no matter how large the table grows.
CREATE INDEX idx_outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;
CREATE INDEX idx_outbox_aggregate   ON outbox (aggregate_type, aggregate_id);

-- Consumer idempotency. At-least-once delivery + this table = exactly-once
-- PROCESSING. Insert must be in the same transaction as the side effect.
CREATE TABLE processed_events (
    event_id       UUID         NOT NULL,
    consumer_group VARCHAR(100) NOT NULL,
    processed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, consumer_group)
);
CREATE INDEX idx_processed_events_at ON processed_events (processed_at);

CREATE TABLE audit_log (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     UUID         NOT NULL UNIQUE,
    event_type   VARCHAR(100) NOT NULL,
    actor_id     UUID,
    subject_type VARCHAR(50)  NOT NULL,
    subject_id   UUID         NOT NULL,
    payload      JSONB        NOT NULL,
    trace_id     VARCHAR(32),
    occurred_at  TIMESTAMPTZ  NOT NULL,
    recorded_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_audit_log_subject  ON audit_log (subject_type, subject_id);
CREATE INDEX idx_audit_log_actor    ON audit_log (actor_id, occurred_at DESC);
CREATE INDEX idx_audit_log_occurred ON audit_log (occurred_at DESC);

-- Presigned uploads: the client PUTs straight to S3, so we need a record of
-- what we authorised in order to reap orphans (upload succeeded, complete
-- never called).
CREATE TABLE pending_uploads (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id       UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    object_key    VARCHAR(1024) NOT NULL UNIQUE,
    file_name     VARCHAR(255)  NOT NULL,
    mime_type     VARCHAR(255)  NOT NULL,
    declared_size BIGINT        NOT NULL,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    completed_at  TIMESTAMPTZ,
    CONSTRAINT pending_uploads_size
        CHECK (declared_size > 0 AND declared_size <= 10485760)
);
CREATE INDEX idx_pending_uploads_stale ON pending_uploads (created_at) WHERE completed_at IS NULL;

-- Idempotency keys (FR8). Postgres-backed so it survives a cache flush;
-- Valkey is the fast path in front of it.
CREATE TABLE idempotency_keys (
    key          VARCHAR(255) PRIMARY KEY,
    user_id      UUID         REFERENCES users(id) ON DELETE CASCADE,
    endpoint     VARCHAR(255) NOT NULL,
    request_hash VARCHAR(64)  NOT NULL,
    status_code  INT,
    response     JSONB,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);
CREATE INDEX idx_idempotency_keys_created ON idempotency_keys (created_at);
