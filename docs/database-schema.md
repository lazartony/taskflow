# TaskFlow Database Schema

PostgreSQL database schema for TaskFlow API. All implementations must use this exact schema.

## Overview

- **Database**: PostgreSQL 15+
- **Naming Convention**: snake_case for tables and columns
- **Primary Keys**: UUID (stored as `uuid` type, generated as `usr_XXXXXX` format in application layer)
- **Timestamps**: `TIMESTAMPTZ` (UTC)
- **Soft Deletes**: `deleted_at` column where applicable

---

## Entity Relationship Diagram

```
┌─────────────────┐
│      users      │
├─────────────────┤
│ id (PK)         │
│ email           │
│ password_hash   │
│ display_name    │
│ avatar_url      │
│ created_at      │
│ updated_at      │
│ deleted_at      │
└────────┬────────┘
         │
         │ 1:N
         │
         ▼
┌─────────────────┐       ┌─────────────────┐
│      tasks      │       │  refresh_tokens │
├─────────────────┤       ├─────────────────┤
│ id (PK)         │       │ id (PK)         │
│ user_id (FK)    │       │ user_id (FK)    │
│ title           │       │ token           │
│ description     │       │ expires_at      │
│ status          │       │ revoked_at      │
│ priority        │       │ created_at      │
│ due_date        │       └─────────────────┘
│ completed_at    │
│ created_at      │
│ updated_at      │
│ deleted_at      │
└────────┬────────┘
         │
         │ 1:N
         │
         ▼
┌─────────────────┐
│   attachments   │
├─────────────────┤
│ id (PK)         │
│ task_id (FK)    │
│ file_name       │
│ file_size       │
│ mime_type       │
│ url             │
│ created_at      │
└─────────────────┘
```

---

## Table Definitions

### users

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(50) NOT NULL,
    avatar_url VARCHAR(2048),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    CONSTRAINT users_display_name_length CHECK (
        LENGTH(display_name) >= 2 AND LENGTH(display_name) <= 50
    ),
    CONSTRAINT users_email_format CHECK (
        email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    )
);

-- Indexes
CREATE INDEX idx_users_email ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_created_at ON users (created_at);
CREATE INDEX idx_users_deleted_at ON users (deleted_at);

-- Updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

**Column Descriptions:**

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY | Unique user identifier |
| `email` | VARCHAR(255) | NOT NULL, UNIQUE | User's email address |
| `password_hash` | VARCHAR(255) | NOT NULL | bcrypt hash (cost 12) |
| `display_name` | VARCHAR(50) | NOT NULL | User's display name (2–50 chars) |
| `avatar_url` | VARCHAR(2048) | NULL | Profile picture URL |
| `created_at` | TIMESTAMPTZ | NOT NULL | Account creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL | Last update timestamp |
| `deleted_at` | TIMESTAMPTZ | NULL | Soft delete timestamp |

---

### tasks

```sql
CREATE TYPE task_status AS ENUM (
    'pending',
    'in_progress',
    'completed',
    'archived'
);

CREATE TYPE task_priority AS ENUM (
    'low',
    'medium',
    'high',
    'urgent'
);

CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    status task_status NOT NULL DEFAULT 'pending',
    priority task_priority NOT NULL DEFAULT 'medium',
    due_date TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    CONSTRAINT tasks_title_length CHECK (
        LENGTH(title) >= 1 AND LENGTH(title) <= 200
    ),
    CONSTRAINT tasks_description_length CHECK (
        description IS NULL OR LENGTH(description) <= 5000
    ),
    CONSTRAINT tasks_due_date_future CHECK (
        due_date IS NULL OR due_date > NOW()
    ),
    CONSTRAINT tasks_completed_at_valid CHECK (
        (status = 'completed' AND completed_at IS NOT NULL) OR
        (status != 'completed' AND completed_at IS NULL) OR
        completed_at IS NULL
    )
);

-- Indexes
CREATE INDEX idx_tasks_user_id ON tasks (user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_status ON tasks (user_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_priority ON tasks (user_id, priority) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_due_date ON tasks (user_id, due_date) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_created_at ON tasks (user_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_status ON tasks (status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_priority ON tasks (priority) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_deleted_at ON tasks (deleted_at);

-- GIN index for full-text search
CREATE INDEX idx_tasks_title_search ON tasks USING GIN (to_tsvector('english', title)) WHERE deleted_at IS NULL;

-- Updated_at trigger
CREATE TRIGGER update_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

**Column Descriptions:**

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY | Unique task identifier |
| `user_id` | UUID | NOT NULL, FK | Owner's user ID |
| `title` | VARCHAR(200) | NOT NULL | Task title (1–200 chars) |
| `description` | TEXT | NULL | Task description (max 5000 chars) |
| `status` | task_status | NOT NULL | Current status (default: pending) |
| `priority` | task_priority | NOT NULL | Priority level (default: medium) |
| `due_date` | TIMESTAMPTZ | NULL | Due date (must be in future) |
| `completed_at` | TIMESTAMPTZ | NULL | Completion timestamp |
| `created_at` | TIMESTAMPTZ | NOT NULL | Creation timestamp |
| `updated_at` | TIMESTAMPTZ | NOT NULL | Last update timestamp |
| `deleted_at` | TIMESTAMPTZ | NULL | Soft delete timestamp |

---

### refresh_tokens

```sql
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT refresh_tokens_expires_future CHECK (
        expires_at > NOW()
    )
);

-- Indexes
CREATE INDEX idx_refresh_tokens_user_id ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_token ON refresh_tokens (token);
CREATE INDEX idx_refresh_tokens_expires_at ON refresh_tokens (expires_at);

-- Partial index for valid (non-revoked, non-expired) tokens
CREATE INDEX idx_refresh_tokens_valid ON refresh_tokens (user_id, token) 
    WHERE revoked_at IS NULL AND expires_at > NOW();
```

**Column Descriptions:**

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY | Unique token identifier |
| `user_id` | UUID | NOT NULL, FK | Associated user ID |
| `token` | VARCHAR(255) | NOT NULL | Hashed refresh token |
| `expires_at` | TIMESTAMPTZ | NOT NULL | Expiration timestamp (7 days) |
| `revoked_at` | TIMESTAMPTZ | NULL | Revocation timestamp (logout) |
| `created_at` | TIMESTAMPTZ | NOT NULL | Creation timestamp |

---

### attachments

```sql
CREATE TABLE attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    file_name VARCHAR(255) NOT NULL,
    file_size BIGINT NOT NULL,
    mime_type VARCHAR(255) NOT NULL,
    url VARCHAR(2048) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT attachments_file_size CHECK (
        file_size > 0 AND file_size <= 10485760  -- 10 MB max
    ),
    CONSTRAINT attachments_file_name_length CHECK (
        LENGTH(file_name) >= 1 AND LENGTH(file_name) <= 255
    )
);

-- Indexes
CREATE INDEX idx_attachments_task_id ON attachments (task_id);
CREATE INDEX idx_attachments_created_at ON attachments (created_at);
```

**Column Descriptions:**

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UUID | PRIMARY KEY | Unique attachment identifier |
| `task_id` | UUID | NOT NULL, FK | Associated task ID |
| `file_name` | VARCHAR(255) | NOT NULL | Original file name |
| `file_size` | BIGINT | NOT NULL | File size in bytes (max 10 MB) |
| `mime_type` | VARCHAR(255) | NOT NULL | File MIME type |
| `url` | VARCHAR(2048) | NOT NULL | Storage URL (S3, Cloudflare R2, etc.) |
| `created_at` | TIMESTAMPTZ | NOT NULL | Upload timestamp |

---

## Migrations

### Migration 001: Initial Schema

```sql
-- File: migrations/001_initial_schema.up.sql

-- Create enum types
CREATE TYPE task_status AS ENUM ('pending', 'in_progress', 'completed', 'archived');
CREATE TYPE task_priority AS ENUM ('low', 'medium', 'high', 'urgent');

-- Create users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(50) NOT NULL,
    avatar_url VARCHAR(2048),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    CONSTRAINT users_display_name_length CHECK (LENGTH(display_name) >= 2 AND LENGTH(display_name) <= 50),
    CONSTRAINT users_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- Create tasks table
CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    status task_status NOT NULL DEFAULT 'pending',
    priority task_priority NOT NULL DEFAULT 'medium',
    due_date TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    CONSTRAINT tasks_title_length CHECK (LENGTH(title) >= 1 AND LENGTH(title) <= 200),
    CONSTRAINT tasks_description_length CHECK (description IS NULL OR LENGTH(description) <= 5000),
    CONSTRAINT tasks_due_date_future CHECK (due_date IS NULL OR due_date > NOW()),
    CONSTRAINT tasks_completed_at_valid CHECK (
        (status = 'completed' AND completed_at IS NOT NULL) OR
        (status != 'completed' AND completed_at IS NULL) OR
        completed_at IS NULL
    )
);

-- Create refresh_tokens table
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT refresh_tokens_expires_future CHECK (expires_at > NOW())
);

-- Create attachments table
CREATE TABLE attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    file_name VARCHAR(255) NOT NULL,
    file_size BIGINT NOT NULL,
    mime_type VARCHAR(255) NOT NULL,
    url VARCHAR(2048) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT attachments_file_size CHECK (file_size > 0 AND file_size <= 10485760),
    CONSTRAINT attachments_file_name_length CHECK (LENGTH(file_name) >= 1 AND LENGTH(file_name) <= 255)
);

-- Create indexes
CREATE INDEX idx_users_email ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_created_at ON users (created_at);
CREATE INDEX idx_users_deleted_at ON users (deleted_at);

CREATE INDEX idx_tasks_user_id ON tasks (user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_status ON tasks (user_id, status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_priority ON tasks (user_id, priority) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_due_date ON tasks (user_id, due_date) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_user_created_at ON tasks (user_id, created_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_status ON tasks (status) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_priority ON tasks (priority) WHERE deleted_at IS NULL;
CREATE INDEX idx_tasks_deleted_at ON tasks (deleted_at);
CREATE INDEX idx_tasks_title_search ON tasks USING GIN (to_tsvector('english', title)) WHERE deleted_at IS NULL;

CREATE INDEX idx_refresh_tokens_user_id ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_token ON refresh_tokens (token);
CREATE INDEX idx_refresh_tokens_expires_at ON refresh_tokens (expires_at);
CREATE INDEX idx_refresh_tokens_valid ON refresh_tokens (user_id, token) WHERE revoked_at IS NULL AND expires_at > NOW();

CREATE INDEX idx_attachments_task_id ON attachments (task_id);
CREATE INDEX idx_attachments_created_at ON attachments (created_at);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Attach triggers
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_tasks_updated_at BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

### Migration 001: Rollback

```sql
-- File: migrations/001_initial_schema.down.sql

DROP TRIGGER IF EXISTS update_users_updated_at ON users;
DROP TRIGGER IF EXISTS update_tasks_updated_at ON tasks;
DROP FUNCTION IF EXISTS update_updated_at_column();

DROP TABLE IF EXISTS attachments CASCADE;
DROP TABLE IF EXISTS refresh_tokens CASCADE;
DROP TABLE IF EXISTS tasks CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP TYPE IF EXISTS task_priority CASCADE;
DROP TYPE IF EXISTS task_status CASCADE;
```

---

## Seed Data (Development)

```sql
-- File: seeds/001_development_data.sql

-- Insert test user (password: TestPass123! - bcrypt hash)
INSERT INTO users (id, email, password_hash, display_name, created_at, updated_at) VALUES
('00000000-0000-0000-0000-000000000001', 'test@example.com', '$2a$12$KIXxwQ8h5qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3qJ3q', 'Test User', NOW(), NOW());

-- Insert sample tasks
INSERT INTO tasks (id, user_id, title, description, status, priority, due_date, created_at, updated_at) VALUES
('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 
 'Complete project documentation', 'Write comprehensive API documentation for all endpoints', 
 'in_progress', 'high', NOW() + INTERVAL '7 days', NOW(), NOW()),
 
('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 
 'Review pull requests', 'Review and merge pending PRs from team members', 
 'pending', 'medium', NOW() + INTERVAL '3 days', NOW(), NOW()),
 
('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 
 'Deploy to production', 'Deploy v2.0 to production environment', 
 'completed', 'urgent', NOW() - INTERVAL '1 day', NOW() - INTERVAL '2 days', NOW() - INTERVAL '1 day');
```

---

## Database Configuration

### Connection String Format

```
postgresql://username:password@host:5432/taskflow?sslmode=require
```

### Environment Variables

```bash
DATABASE_URL=postgresql://postgres:password@localhost:5432/taskflow_dev
DATABASE_POOL_SIZE=10
DATABASE_MAX_IDLE_CONNECTIONS=5
DATABASE_CONNECTION_MAX_LIFETIME=30m
```

### Recommended Settings

```sql
-- PostgreSQL configuration (postgresql.conf)
shared_preload_libraries = 'pg_stat_statements'
log_min_duration_statement = 100  -- Log queries > 100ms
log_statement = 'none'
log_checkpoints = on
log_connections = on
log_disconnections = on
```

---

## Queries

### Common Queries

#### Get user by email (login)
```sql
SELECT id, email, password_hash, display_name, avatar_url, created_at, updated_at
FROM users
WHERE email = $1 AND deleted_at IS NULL;
```

#### Get tasks with pagination and filtering
```sql
SELECT id, user_id, title, description, status, priority, due_date, completed_at, created_at, updated_at
FROM tasks
WHERE user_id = $1 
  AND deleted_at IS NULL
  AND ($2::task_status IS NULL OR status = $2)
  AND ($3::task_priority IS NULL OR priority = $3)
  AND ($4::TIMESTAMPTZ IS NULL OR due_date >= $4)
  AND ($5::TIMESTAMPTZ IS NULL OR due_date <= $5)
  AND ($6::TEXT IS NULL OR title ILIKE $6 OR description ILIKE $6)
ORDER BY created_at DESC
LIMIT $7 OFFSET $8;
```

#### Count tasks for pagination
```sql
SELECT COUNT(*) as total
FROM tasks
WHERE user_id = $1 
  AND deleted_at IS NULL
  AND ($2::task_status IS NULL OR status = $2)
  AND ($3::task_priority IS NULL OR priority = $3)
  AND ($4::TIMESTAMPTZ IS NULL OR due_date >= $4)
  AND ($5::TIMESTAMPTZ IS NULL OR due_date <= $5)
  AND ($6::TEXT IS NULL OR title ILIKE $6 OR description ILIKE $6);
```

#### Get valid refresh token
```sql
SELECT id, user_id, token, expires_at, revoked_at, created_at
FROM refresh_tokens
WHERE user_id = $1 
  AND token = $2 
  AND revoked_at IS NULL 
  AND expires_at > NOW()
LIMIT 1;
```

#### Get task attachments
```sql
SELECT id, task_id, file_name, file_size, mime_type, url, created_at
FROM attachments
WHERE task_id = $1
ORDER BY created_at DESC;
```

---

## Notes for Implementation

1. **UUID Generation**: Database uses `gen_random_uuid()` but application layer should generate IDs in format `usr_XXXXXX`, `tsk_XXXXXX`, etc. for better readability in logs and APIs.

2. **Soft Deletes**: All queries must filter `WHERE deleted_at IS NULL` for non-deleted records.

3. **Timezones**: All timestamps are stored in UTC. Convert to user's local timezone in application layer.

4. **Password Hashing**: Use bcrypt with cost factor 12. Store only the hash, never plaintext.

5. **Token Storage**: Store hashed refresh tokens (SHA-256) in database, not plaintext.

6. **Connection Pooling**: Use connection pooling in all implementations (pgx for Rust, asyncpg for Python, etc.).

7. **Migrations**: Use migration tools:
   - Go: `golang-migrate/migrate`
   - Rust: `sqlx` or `diesel`
   - Python: `alembic`
   - C#: Entity Framework Core migrations
   - TypeScript: `prisma migrate` or `drizzle-kit`