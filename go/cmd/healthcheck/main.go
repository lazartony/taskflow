// Command healthcheck is the container HEALTHCHECK for the distroless image.
//
// Distroless has no shell, no curl and no wget, so the healthcheck has to be a
// binary. This one is a few hundred KB, statically linked, and does exactly
// one thing: GET /api/v1/health/live and exit 0 on 200, 1 on anything else.
//
// It deliberately probes LIVE, not READY. Docker restarts an unhealthy
// container; restarting because the database blipped is the outage this whole
// three-endpoint split exists to prevent (OBS5.1).
package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// The deadline lives on the context rather than only on http.Client.Timeout:
	// a client timeout does not cancel work already in flight, and `noctx` is
	// enabled precisely so request paths cannot skip cancellation.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	url := "http://" + net.JoinHostPort("127.0.0.1", port) + "/api/v1/health/live"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		os.Exit(1)
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		os.Exit(1)
	}
	defer resp.Body.Close() //nolint:errcheck

	if resp.StatusCode != http.StatusOK {
		os.Exit(1)
	}
	os.Exit(0)
}
