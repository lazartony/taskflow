// Command server is the TaskFlow Go API.
//
// This is a SKELETON. It starts, connects to Postgres, serves the three health
// probes for real, and answers 501 NOT_IMPLEMENTED for every other /api/v1
// route. Everything else is a TODO pointing at the roadmap phase that builds it.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/taskflow/taskflow/go/internal/config"
	"github.com/taskflow/taskflow/go/internal/handlers"
	"github.com/taskflow/taskflow/go/internal/httpx"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	log := newLogger(cfg)
	slog.SetDefault(log)

	// ── Database pool ────────────────────────────────────────────────────
	poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return err
	}
	poolCfg.MaxConns = cfg.DatabasePoolSize
	poolCfg.MinConns = cfg.DatabaseMinIdle
	// TODO(Phase 3): MaxConnLifetime / MaxConnIdleTime from DATABASE_MAX_LIFETIME,
	// and a statement_timeout from DATABASE_STATEMENT_TIMEOUT set via
	// poolCfg.ConnConfig.RuntimeParams.

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		return err
	}
	log.Info("database pool ready", slog.Int("max_conns", int(cfg.DatabasePoolSize)))

	// ── Router ───────────────────────────────────────────────────────────
	health := handlers.NewHealth(pool)

	r := chi.NewRouter()
	r.Use(middleware.Recoverer) // TODO(Phase 1): replace with internal/middleware/recovery.go
	r.Use(httpx.RequestID)
	r.Use(requestLogger(log))

	// TODO(Phase 1): security headers, CORS, body limit, auth middleware.
	// TODO(Phase 2): otelhttp instrumentation wrapping the whole router.
	// TODO(Phase 4): valkey-backed rate limiting.
	// TODO(Phase 5): concurrency limiter for load shedding.

	r.Route("/api/v1", func(r chi.Router) {
		r.Mount("/health", health.Routes())

		// Everything else is deliberately 501. As each group is implemented,
		// mount the real router ABOVE this catch-all and the 501 stops firing
		// for those paths.
		//
		// TODO(Phase 1): r.Mount("/auth", authHandler.Routes())
		// TODO(Phase 1): r.Mount("/tasks", taskHandler.Routes())
		// TODO(Phase 10): r.Mount("/attachments", attachmentHandler.Routes())
		r.HandleFunc("/*", httpx.NotImplemented)
	})

	srv := &http.Server{
		Addr:              net.JoinHostPort("", cfg.Port),
		Handler:           r,
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
		// TODO(Phase 5): REQUEST_TIMEOUT via http.TimeoutHandler or per-route
		// context deadlines.
	}

	// ── Serve ────────────────────────────────────────────────────────────
	serverErr := make(chan error, 1)
	go func() {
		log.Info("http server listening", slog.String("addr", srv.Addr), slog.String("env", cfg.Env))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
	}()

	// ── Graceful shutdown ────────────────────────────────────────────────
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	select {
	case err := <-serverErr:
		return err
	case sig := <-stop:
		log.Info("shutdown signal received", slog.String("signal", sig.String()))
	}

	// The pre-stop delay exists so the load balancer notices we are going away
	// before we stop accepting. Without it, in-flight routing sends requests to
	// a socket that is already closed.
	// TODO(if you deploy this): flip readiness to "not ready" here as well, so an
	// orchestrator pulls this instance out of rotation during the delay. Kubernetes
	// itself is off the roadmap on purpose — see "Cut: Kubernetes deployment" in
	// docs/learning-roadmap.md.
	time.Sleep(cfg.ShutdownPrestopDelay)

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.ShutdownGracePeriod)
	defer shutdownCancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", slog.String("error", err.Error()))
		return err
	}

	// TODO(Phase 6): drain the outbox relay and the Kafka consumer here, before
	// the pool closes — they hold connections too.
	pool.Close()
	log.Info("shutdown complete")
	return nil
}

// newLogger returns a JSON slog handler writing to stdout, with the service
// resource attributes attached to every line (§4.1 of the observability spec).
//
// TODO(Phase 2): replace the timestamp/level rewriting below with an
// OTel-aware handler that also injects trace_id and span_id.
func newLogger(cfg *config.Config) *slog.Logger {
	level := slog.LevelInfo
	switch cfg.LogLevel {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}

	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.TimeKey:
				return slog.String("timestamp", a.Value.Time().UTC().Format(httpx.TimestampFormat))
			case slog.MessageKey:
				return slog.String("message", a.Value.String())
			case slog.LevelKey:
				return slog.String("level", strings.ToLower(a.Value.String()))
			}
			return a
		},
	})

	return slog.New(h).With(slog.Group("service",
		slog.String("name", cfg.ServiceName),
		slog.String("version", cfg.ServiceVersion),
	))
}

// requestLogger emits one canonical log line per request.
//
// TODO(Phase 2): add http.route (the chi route pattern, never the raw path —
// OBS3.5), trace_id, span_id and user.id.
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

			next.ServeHTTP(ww, r)

			log.Info("http request completed",
				slog.Group("http",
					slog.Group("request", slog.String("method", r.Method)),
					slog.String("route", chi.RouteContext(r.Context()).RoutePattern()),
					slog.Group("response", slog.Int("status_code", ww.Status())),
				),
				slog.Group("url", slog.String("path", r.URL.Path)),
				slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000.0),
				slog.String("request_id", httpx.RequestIDFrom(r.Context())),
			)
		})
	}
}
