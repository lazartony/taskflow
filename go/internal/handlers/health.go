// Package handlers holds the HTTP handlers. Today that is only health; the
// task, auth and attachment handlers arrive in Phase 1.
package handlers

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/taskflow/taskflow/go/internal/httpx"
)

const (
	// readyCacheTTL implements OBS5.4 — a readiness probe that hammers the
	// database once per replica per second is itself an outage risk.
	readyCacheTTL = 1 * time.Second
	// readyCheckTimeout is the hard ceiling on the dependency check (OBS5.4).
	readyCheckTimeout = 2 * time.Second
)

// Health owns the three probe endpoints.
type Health struct {
	pool *pgxpool.Pool

	mu        sync.Mutex
	checkedAt time.Time
	lastErr   error
}

// NewHealth wires the probes to the connection pool.
func NewHealth(pool *pgxpool.Pool) *Health {
	return &Health{pool: pool}
}

// Routes mounts /live, /ready and /startup, plus the bare alias.
func (h *Health) Routes() chi.Router {
	r := chi.NewRouter()
	r.Get("/", h.Ready) // OBS5.5 — /api/v1/health is an alias of /health/ready
	r.Get("/live", h.Live)
	r.Get("/ready", h.Ready)
	r.Get("/startup", h.Startup)
	return r
}

// Live answers "is this process wedged" and nothing else (OBS5.1).
//
// It must never touch the database. A liveness probe that checks a dependency
// turns a recoverable database blip into every replica being killed at once.
func (h *Health) Live(w http.ResponseWriter, r *http.Request) {
	httpx.WriteSuccess(w, r, http.StatusOK, map[string]string{"status": "alive"})
}

// Ready answers "should I get traffic right now" (OBS5.2).
//
// TODO(Phase 4): add the Valkey PING to this check.
// TODO(Phase 6): add the Kafka broker metadata check.
// Both must degrade the same way: a failed optional dependency should be
// reported in data.checks without necessarily failing the whole probe.
func (h *Health) Ready(w http.ResponseWriter, r *http.Request) {
	// The envelope invariant is absolute: a >=400 status carries
	// success:false and error.code, never a success envelope. The check detail
	// travels in error.details so an operator still sees which dependency failed.
	if err := h.checkCached(r.Context()); err != nil {
		httpx.WriteErrorDetails(w, r, http.StatusServiceUnavailable,
			"SERVICE_UNAVAILABLE", "One or more dependencies are unavailable",
			map[string]any{
				"status": "not_ready",
				"checks": map[string]string{"database": "down"},
			})
		return
	}

	httpx.WriteSuccess(w, r, http.StatusOK, map[string]any{
		"status": "ready",
		"checks": map[string]string{"database": "up"},
	})
}

// Startup reports 200 once the pool exists (OBS5.3). Because the pool is
// constructed and pinged before the server starts listening, reaching this
// handler at all means startup succeeded.
//
// TODO(Phase 0/12): also assert the expected schema_migrations version so a
// replica running against an un-migrated database never reports started.
func (h *Health) Startup(w http.ResponseWriter, r *http.Request) {
	httpx.WriteSuccess(w, r, http.StatusOK, map[string]string{"status": "started"})
}

// checkCached runs SELECT 1, memoising the result for readyCacheTTL.
func (h *Health) checkCached(ctx context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()

	if !h.checkedAt.IsZero() && time.Since(h.checkedAt) < readyCacheTTL {
		return h.lastErr
	}

	checkCtx, cancel := context.WithTimeout(ctx, readyCheckTimeout)
	defer cancel()

	var one int
	err := h.pool.QueryRow(checkCtx, "SELECT 1").Scan(&one)

	h.checkedAt = time.Now()
	h.lastErr = err
	return err
}
