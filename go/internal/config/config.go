// Package config loads runtime configuration from the environment.
//
// Every key here appears in the repository-root .env.example. Only the subset
// the skeleton actually uses is parsed; the rest arrive in later phases.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config is the subset of .env.example that the skeleton needs today.
type Config struct {
	Port                 string
	Env                  string
	ServiceName          string
	ServiceVersion       string
	LogLevel             string
	DatabaseURL          string
	DatabasePoolSize     int32
	DatabaseMinIdle      int32
	DatabaseAcquireTO    time.Duration
	ShutdownGracePeriod  time.Duration
	ShutdownPrestopDelay time.Duration
	ReadHeaderTimeout    time.Duration

	// TODO(Phase 1): JWTSecret, JWTIssuer, JWTAudience, JWTAccessExpiry,
	// JWTRefreshExpiry, BcryptCost, CORSOrigins, MaxBodyBytes.
	// TODO(Phase 4): ValkeyURL, CacheEnabled, RateLimit* keys.
	// TODO(Phase 6): KafkaBrokers, Outbox* keys.
	// TODO(Phase 10): S3Endpoint, S3Bucket, S3AccessKey, S3SecretKey.
}

// Load reads the environment and fails fast on anything missing or malformed.
// Failing at startup beats failing on the first request that needs the value.
func Load() (*Config, error) {
	c := &Config{
		Port:                 env("PORT", "8080"),
		Env:                  env("ENV", "development"),
		ServiceName:          env("OTEL_SERVICE_NAME", "taskflow-go"),
		ServiceVersion:       env("OTEL_SERVICE_VERSION", "1.0.0"),
		LogLevel:             env("LOG_LEVEL", "info"),
		DatabaseURL:          os.Getenv("DATABASE_URL"),
		ShutdownGracePeriod:  envDuration("SHUTDOWN_GRACE_PERIOD", 30*time.Second),
		ShutdownPrestopDelay: envDuration("SHUTDOWN_PRESTOP_DELAY", 5*time.Second),
		ReadHeaderTimeout:    envDuration("READ_HEADER_TIMEOUT", 5*time.Second),
	}

	if c.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}

	// pgxpool takes int32, so these are parsed AS int32 rather than parsed as
	// int and converted. A conversion would wrap silently: POOL_SIZE=2147483648
	// becomes a negative pool size and the failure surfaces much later, as a
	// pool that refuses every acquire.
	poolSize, err := envInt32("DATABASE_POOL_SIZE", 10)
	if err != nil {
		return nil, err
	}
	c.DatabasePoolSize = poolSize

	minIdle, err := envInt32("DATABASE_MIN_IDLE", 2)
	if err != nil {
		return nil, err
	}
	c.DatabaseMinIdle = minIdle

	acquireMS, err := envInt("DATABASE_ACQUIRE_TIMEOUT_MS", 2000)
	if err != nil {
		return nil, err
	}
	c.DatabaseAcquireTO = time.Duration(acquireMS) * time.Millisecond

	return c, nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got %q", key, v)
	}
	return n, nil
}

// envInt32 parses at the destination's width, so a value that does not fit is
// rejected here with the key named rather than wrapping into a nonsense number.
func envInt32(key string, fallback int32) (int32, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.ParseInt(v, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("%s must be a 32-bit integer, got %q", key, v)
	}
	return int32(n), nil
}

func envDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}
