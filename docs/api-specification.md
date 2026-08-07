# TaskFlow API - API Specification

RESTful API for TaskFlow task management system. Base URL: `/api/v1`

## Authentication

All endpoints except `/auth/register` and `/auth/login` require authentication via JWT Bearer token.

**Header Format:**
```
Authorization: Bearer <access_token>
```

## Standard Response Formats

### Success Response

```json
{
  "success": true,
  "data": { ... },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

### Error Response

```json
{
  "success": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable error message",
    "details": { ... }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

### Pagination Response

```json
{
  "success": true,
  "data": [ ... ],
  "pagination": {
    "page": 1,
    "pageSize": 20,
    "totalItems": 150,
    "totalPages": 8,
    "hasNext": true,
    "hasPrev": false
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

## Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `VALIDATION_ERROR` | 400 | Request validation failed |
| `INVALID_CREDENTIALS` | 401 | Email or password incorrect |
| `UNAUTHORIZED` | 401 | Missing or invalid token |
| `FORBIDDEN` | 403 | Insufficient permissions |
| `NOT_FOUND` | 404 | Resource not found |
| `CONFLICT` | 409 | Resource already exists |
| `RATE_LIMIT_EXCEEDED` | 429 | Too many requests |
| `INTERNAL_ERROR` | 500 | Server error |

---

## Endpoints

### Authentication

#### POST /auth/register

Register a new user account.

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "SecurePass123!",
  "displayName": "John Doe"
}
```

**Validation Rules:**
- `email`: Valid email format, unique, max 255 characters
- `password`: Min 8 characters, at least 1 uppercase, 1 lowercase, 1 number
- `displayName`: 2–50 characters

**Success Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "user": {
      "id": "usr_abc123",
      "email": "user@example.com",
      "displayName": "John Doe",
      "createdAt": "2026-08-07T12:34:56.789Z"
    },
    "tokens": {
      "accessToken": "eyJhbGciOiJIUzI1NiIs...",
      "refreshToken": "eyJhbGciOiJIUzI1NiIs...",
      "expiresIn": 900
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `400` - `VALIDATION_ERROR` if email format invalid or password weak
- `409` - `CONFLICT` if email already exists

---

#### POST /auth/login

Authenticate user and receive tokens.

**Request Body:**
```json
{
  "email": "user@example.com",
  "password": "SecurePass123!"
}
```

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "user": {
      "id": "usr_abc123",
      "email": "user@example.com",
      "displayName": "John Doe"
    },
    "tokens": {
      "accessToken": "eyJhbGciOiJIUzI1NiIs...",
      "refreshToken": "eyJhbGciOiJIUzI1NiIs...",
      "expiresIn": 900
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `401` - `INVALID_CREDENTIALS` if email or password incorrect

---

#### POST /auth/refresh

Refresh access token using refresh token.

**Request Body:**
```json
{
  "refreshToken": "eyJhbGciOiJIUzI1NiIs..."
}
```

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "tokens": {
      "accessToken": "eyJhbGciOiJIUzI1NiIs...",
      "refreshToken": "eyJhbGciOiJIUzI1NiIs...",
      "expiresIn": 900
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `401` - `UNAUTHORIZED` if refresh token invalid or expired

---

#### POST /auth/logout

Invalidate refresh token and log out user.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Request Body:**
```json
{
  "refreshToken": "eyJhbGciOiJIUzI1NiIs..."
}
```

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "message": "Successfully logged out"
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

#### GET /auth/me

Get current authenticated user profile.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "user": {
      "id": "usr_abc123",
      "email": "user@example.com",
      "displayName": "John Doe",
      "avatarUrl": "https://example.com/avatar.jpg",
      "createdAt": "2026-08-07T12:34:56.789Z",
      "updatedAt": "2026-08-07T12:34:56.789Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

#### PUT /auth/profile

Update user profile.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Request Body:**
```json
{
  "displayName": "John Updated",
  "avatarUrl": "https://example.com/new-avatar.jpg"
}
```

**Validation Rules:**
- `displayName`: 2–50 characters (optional)
- `avatarUrl`: Valid URL (optional)

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "user": {
      "id": "usr_abc123",
      "email": "user@example.com",
      "displayName": "John Updated",
      "avatarUrl": "https://example.com/new-avatar.jpg",
      "updatedAt": "2026-08-07T12:34:56.789Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

### Tasks

#### GET /tasks

List user's tasks with pagination and filtering.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `page` | integer | 1 | Page number (1-indexed) |
| `pageSize` | integer | 20 | Items per page (max 100) |
| `status` | string | - | Filter by status: `pending`, `in_progress`, `completed`, `archived` |
| `priority` | string | - | Filter by priority: `low`, `medium`, `high`, `urgent` |
| `search` | string | - | Search in title and description |
| `dueDateFrom` | date | - | Filter tasks due on or after this date (ISO 8601) |
| `dueDateTo` | date | - | Filter tasks due on or before this date (ISO 8601) |
| `sortBy` | string | `createdAt` | Sort field: `createdAt`, `updatedAt`, `dueDate`, `priority` |
| `sortOrder` | string | `desc` | Sort order: `asc`, `desc` |

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": "tsk_abc123",
      "title": "Complete project documentation",
      "description": "Write comprehensive API documentation",
      "status": "in_progress",
      "priority": "high",
      "dueDate": "2026-08-15T00:00:00.000Z",
      "completedAt": null,
      "createdAt": "2026-08-01T10:00:00.000Z",
      "updatedAt": "2026-08-05T14:30:00.000Z"
    }
  ],
  "pagination": {
    "page": 1,
    "pageSize": 20,
    "totalItems": 45,
    "totalPages": 3,
    "hasNext": true,
    "hasPrev": false
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

#### POST /tasks

Create a new task.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Request Body:**
```json
{
  "title": "Complete project documentation",
  "description": "Write comprehensive API documentation",
  "status": "pending",
  "priority": "high",
  "dueDate": "2026-08-15T00:00:00.000Z"
}
```

**Validation Rules:**
- `title`: Required, 1–200 characters
- `description`: Optional, max 5000 characters
- `status`: Optional, default `pending`, one of: `pending`, `in_progress`, `completed`, `archived`
- `priority`: Optional, default `medium`, one of: `low`, `medium`, `high`, `urgent`
- `dueDate`: Optional, ISO 8601 date, must be in future

**Success Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "task": {
      "id": "tsk_abc123",
      "title": "Complete project documentation",
      "description": "Write comprehensive API documentation",
      "status": "pending",
      "priority": "high",
      "dueDate": "2026-08-15T00:00:00.000Z",
      "completedAt": null,
      "createdAt": "2026-08-07T12:34:56.789Z",
      "updatedAt": "2026-08-07T12:34:56.789Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `400` - `VALIDATION_ERROR` if validation fails

---

#### GET /tasks/:id

Get a single task by ID.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Task ID |

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "task": {
      "id": "tsk_abc123",
      "title": "Complete project documentation",
      "description": "Write comprehensive API documentation",
      "status": "in_progress",
      "priority": "high",
      "dueDate": "2026-08-15T00:00:00.000Z",
      "completedAt": null,
      "createdAt": "2026-08-01T10:00:00.000Z",
      "updatedAt": "2026-08-05T14:30:00.000Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `404` - `NOT_FOUND` if task doesn't exist or user doesn't own it

---

#### PUT /tasks/:id

Update an existing task.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Task ID |

**Request Body (all fields optional):**
```json
{
  "title": "Updated project documentation",
  "description": "Updated description",
  "status": "completed",
  "priority": "urgent",
  "dueDate": "2026-08-20T00:00:00.000Z"
}
```

**Validation Rules:**
- Same as POST /tasks
- `status` change to `completed` auto-sets `completedAt` timestamp

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "task": {
      "id": "tsk_abc123",
      "title": "Updated project documentation",
      "description": "Updated description",
      "status": "completed",
      "priority": "urgent",
      "dueDate": "2026-08-20T00:00:00.000Z",
      "completedAt": "2026-08-07T12:34:56.789Z",
      "createdAt": "2026-08-01T10:00:00.000Z",
      "updatedAt": "2026-08-07T12:34:56.789Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `400` - `VALIDATION_ERROR` if validation fails
- `404` - `NOT_FOUND` if task doesn't exist or user doesn't own it

---

#### DELETE /tasks/:id

Delete a task (soft delete).

**Headers:**
```
Authorization: Bearer <access_token>
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Task ID |

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "message": "Task deleted successfully"
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `404` - `NOT_FOUND` if task doesn't exist or user doesn't own it

---

### Task Attachments

#### POST /tasks/:taskId/attachments

Upload a file attachment to a task.

**Headers:**
```
Authorization: Bearer <access_token>
Content-Type: multipart/form-data
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `taskId` | string | Task ID |

**Form Data:**
| Field | Type | Description |
|-------|------|-------------|
| `file` | file | File to upload (max 10 MB) |

**Success Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "attachment": {
      "id": "att_abc123",
      "taskId": "tsk_abc123",
      "fileName": "document.pdf",
      "fileSize": 1024000,
      "mimeType": "application/pdf",
      "url": "https://storage.example.com/attachments/att_abc123/document.pdf",
      "createdAt": "2026-08-07T12:34:56.789Z"
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

**Error Responses:**
- `400` - `VALIDATION_ERROR` if file too large or invalid type
- `404` - `NOT_FOUND` if task doesn't exist

---

#### GET /tasks/:taskId/attachments

List attachments for a task.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `taskId` | string | Task ID |

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": "att_abc123",
      "taskId": "tsk_abc123",
      "fileName": "document.pdf",
      "fileSize": 1024000,
      "mimeType": "application/pdf",
      "url": "https://storage.example.com/attachments/att_abc123/document.pdf",
      "createdAt": "2026-08-07T12:34:56.789Z"
    }
  ],
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

#### DELETE /tasks/:taskId/attachments/:attachmentId

Delete an attachment.

**Headers:**
```
Authorization: Bearer <access_token>
```

**Path Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `taskId` | string | Task ID |
| `attachmentId` | string | Attachment ID |

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "message": "Attachment deleted successfully"
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

---

### Real-time Updates

#### GET /ws/events

WebSocket endpoint for real-time task updates.

**Query Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | string | JWT access token |

**Connection URL:**
```
ws://api.example.com/api/v1/ws/events?token=<access_token>
```

**Client Messages:**
```json
{
  "type": "subscribe",
  "taskId": "tsk_abc123"
}
```

**Server Messages:**
```json
{
  "type": "task.created",
  "data": {
    "id": "tsk_abc123",
    "title": "New task",
    "status": "pending",
    "createdAt": "2026-08-07T12:34:56.789Z"
  },
  "timestamp": "2026-08-07T12:34:56.789Z"
}
```

**Event Types:**
- `task.created`
- `task.updated`
- `task.deleted`
- `attachment.added`
- `attachment.removed`

---

### System

#### GET /health

Health check endpoint (no authentication required).

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "status": "healthy",
    "version": "1.0.0",
    "timestamp": "2026-08-07T12:34:56.789Z",
    "services": {
      "database": "connected",
      "storage": "connected"
    }
  }
}
```

---

## Data Models

### User

```typescript
interface User {
  id: string;              // Format: usr_XXXXXX
  email: string;           // Unique, max 255 chars
  passwordHash: string;    // bcrypt hash
  displayName: string;     // 2–50 chars
  avatarUrl?: string;      // Optional, valid URL
  createdAt: Date;
  updatedAt: Date;
  deletedAt?: Date;        // Soft delete
}
```

### Task

```typescript
interface Task {
  id: string;              // Format: tsk_XXXXXX
  userId: string;          // Owner's user ID
  title: string;           // 1–200 chars
  description?: string;    // Max 5000 chars
  status: TaskStatus;      // Enum
  priority: TaskPriority;  // Enum
  dueDate?: Date;
  completedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
  deletedAt?: Date;        // Soft delete
}

enum TaskStatus {
  PENDING = 'pending',
  IN_PROGRESS = 'in_progress',
  COMPLETED = 'completed',
  ARCHIVED = 'archived'
}

enum TaskPriority {
  LOW = 'low',
  MEDIUM = 'medium',
  HIGH = 'high',
  URGENT = 'urgent'
}
```

### RefreshToken

```typescript
interface RefreshToken {
  id: string;              // Format: rft_XXXXXX
  userId: string;
  token: string;           // Hashed refresh token
  expiresAt: Date;
  revokedAt?: Date;
  createdAt: Date;
}
```

### Attachment

```typescript
interface Attachment {
  id: string;              // Format: att_XXXXXX
  taskId: string;
  fileName: string;
  fileSize: number;        // Bytes
  mimeType: string;
  url: string;             // Storage URL
  createdAt: Date;
}
```

## Rate Limiting

| Endpoint | Limit |
|----------|-------|
| /auth/* | 10 requests/minute |
| /tasks/* | 100 requests/minute |
| /ws/events | 5 concurrent connections per user |

**Rate Limit Response Headers:**
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1691409600
```

**429 Response:**
```json
{
  "success": false,
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many requests. Please try again in 45 seconds.",
    "details": {
      "retryAfter": 45
    }
  },
  "meta": {
    "requestId": "req_abc123xyz",
    "timestamp": "2026-08-07T12:34:56.789Z"
  }
}
```

## Testing

### Test Credentials (Development)

```
Email: test@example.com
Password: TestPass123!
```

### Sample Test Flow

1. POST /auth/register → Get tokens
2. POST /tasks → Create task
3. GET /tasks → List tasks
4. GET /tasks/:id → Get single task
5. PUT /tasks/:id → Update task
6. DELETE /tasks/:id → Delete task