# TaskFlow API - Requirements Specification

> **Read `requirements-addendum.md` alongside this.** This document is the original
> requirement set and the source of the `FR*` / `NFR*` / `C*` identifiers every other spec
> cites. Some rows below have since been **superseded** — the addendum replaced them, and
> the rows are marked inline. A row marked superseded is not a requirement any more; build
> the replacement it names.

A multi-language backend implementation project for learning Go, Rust, Python, C#, and TypeScript.

## Project Overview

**TaskFlow** is a task management API that demonstrates core backend development patterns across five different technology stacks. The system supports user authentication, task CRUD operations, real-time updates, and file attachments.

## Functional Requirements

### FR1: User Management

| ID | Requirement | Priority |
|----|-------------|----------|
| FR1.1 | Users can register with email, password, and display name | High |
| FR1.2 | Users can log in with email and password | High |
| FR1.3 | Users receive JWT access token (15 min expiry) and refresh token (7 days expiry) | High |
| FR1.4 | Users can refresh their access token using a valid refresh token | High |
| FR1.5 | Users can log out, invalidating their refresh token | Medium |
| FR1.6 | Users can update their profile (display name, avatar URL) | Medium |
| FR1.7 | Users can delete their account (soft delete) | Low |

### FR2: Task Management

| ID | Requirement | Priority |
|----|-------------|----------|
| FR2.1 | Users can create tasks with title, description, status, priority, and due date | High |
| FR2.2 | Users can view a list of their tasks with pagination and filtering | High |
| FR2.3 | Users can view a single task by ID | High |
| FR2.4 | Users can update task fields (title, description, status, priority, due date) | High |
| FR2.5 | Users can delete tasks | High |
| FR2.6 | Users can filter tasks by status, priority, date range, and search query | Medium |
| FR2.7 | Tasks support soft delete (can be recovered within 30 days) | Low |

### FR3: Real-time Features

| ID | Requirement | Priority |
|----|-------------|----------|
| FR3.1 | Users receive real-time notifications when tasks are created, updated, or deleted | Medium |
| FR3.2 | Real-time updates delivered via WebSocket or Server-Sent Events (SSE) | Medium |
| FR3.3 | Users can subscribe to specific task channels | Low |

### FR4: File Attachments

| ID | Requirement | Priority |
|----|-------------|----------|
| FR4.1 | Users can upload file attachments to tasks (max 10 MB per file) | Medium |
| FR4.2 | Users can view a list of attachments for a task | Medium |
| FR4.3 | Users can download attachments | Medium |
| FR4.4 | Users can delete attachments | Low |

### FR5: System Features

| ID | Requirement | Priority |
|----|-------------|----------|
| FR5.1 | API enforces rate limiting (100 requests/minute per user) — **amended**: must be enforced in shared state (Valkey), not per-process | High |
| FR5.2 | All endpoints require authentication except /api/v1/auth/register and /api/v1/auth/login | High |
| FR5.3 | API supports CORS for specified origins | High |
| FR5.4 | All errors return standardized error responses | High |
| FR5.5 | API logs all requests with correlation IDs | Medium |

## Non-Functional Requirements

### Performance

| ID | Requirement |
|----|-------------|
| NFR1 | API responds within 200ms for 95th percentile of requests (p95) |
| NFR2 | Support at least 1,000 concurrent users |
| NFR3 | Database queries complete within 50ms for simple operations |

### Security

| ID | Requirement |
|----|-------------|
| NFR4 | All passwords hashed using bcrypt (cost factor 12) |
| NFR5 | JWT tokens signed with HS256 or RS256 |
| NFR6 | All API endpoints served over HTTPS |
| NFR7 | SQL injection prevented via parameterized queries or ORM |
| NFR8 | Input validation on all user-provided data |

### Reliability

| ID | Requirement |
|----|-------------|
| NFR9 | 99% uptime target |
| NFR10 | Graceful shutdown with in-flight request completion |
| NFR11 | Database migrations are versioned and reversible |

### Observability

| ID | Requirement |
|----|-------------|
| ~~NFR12~~ | ~~Structured JSON logging with log levels~~ — **superseded by OBS2.1–2.7** (observability spec) |
| ~~NFR13~~ | ~~Request logged with correlation ID~~ — **superseded by OBS2.2, OBS2.4**: trace-based correlation replaces bare request IDs |
| ~~NFR14~~ | ~~Single health endpoint returning database status~~ — **superseded by OBS5.1–5.5**: split into liveness / readiness / startup. A single endpoint that checks the database fails liveness on every replica during a blip and the orchestrator kills them all |

## Technical Constraints

| Constraint | Description |
|------------|-------------|
| C1 | All implementations must use PostgreSQL as the database — **amended**: pinned to PostgreSQL 18, `pg_stat_statements` required |
| C2 | All implementations must use Docker for containerization |
| C3 | All implementations must include comprehensive test suites |
| C4 | All implementations must follow their language's idiomatic patterns |
| C5 | API response formats must be identical across all implementations |
| C6 | Database schema must be identical across all implementations |

## Out of Scope

- OAuth2/social login (Google, GitHub, etc.)
- Two-factor authentication (2FA)
- Email verification on registration
- Password reset flow
- Task sharing or collaboration
- Mobile application
- Frontend UI

## Success Criteria

The project is successful when:

1. All five implementations (Go, Rust, Python, C#, TypeScript) pass the same API test suite
2. All functional requirements are met in each implementation
3. Performance benchmarks are documented and comparable
4. Each implementation follows language-specific best practices
5. Documentation is complete for onboarding new developers