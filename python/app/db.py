"""PostgreSQL connection pool.

``asyncpg`` owns its own pool; there is no separate pooling library to bolt on.
``min_size``/``max_size`` map to ``DATABASE_MIN_IDLE``/``DATABASE_POOL_SIZE``.
"""

from __future__ import annotations

import asyncpg

from app.config import Settings


async def create_pool(settings: Settings) -> asyncpg.Pool:
    """Creates the pool and opens ``min_size`` connections eagerly.

    asyncpg connects during ``create_pool``, so a bad DSN or an unreachable
    database fails here rather than on the first query.
    """
    return await asyncpg.create_pool(
        dsn=settings.database_url,
        min_size=settings.database_min_idle,
        max_size=settings.database_pool_size,
        timeout=settings.database_acquire_timeout_s,
        # asyncpg caches prepared statements per connection. That breaks behind
        # a transaction-mode pooler like PgBouncer; revisit in Phase 3 if one
        # ever sits in front of this service.
        # TODO(Phase 3): max_inactive_connection_lifetime from
        #   DATABASE_MAX_LIFETIME, and a statement_timeout via
        #   server_settings={"statement_timeout": "5000"}.
        # TODO(Phase 2): wrap acquire/execute so each query opens a CLIENT span
        #   with the statement, parameters stripped (OBS4.2).
    )


async def ping(pool: asyncpg.Pool) -> None:
    """Cheap liveness query for the readiness probe."""
    await pool.fetchval("SELECT 1")
