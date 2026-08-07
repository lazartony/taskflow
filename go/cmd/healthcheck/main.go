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
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"
)

func main() {
	// PORT is parsed to an int rather than pasted into the URL as a string. Two
	// reasons, and only one of them is the linter:
	//
	//   - A malformed PORT should fail the probe here, not produce a URL that
	//     cannot be dialled and an error three lines later.
	//   - gosec's G704 (SSRF via taint analysis) follows os.Getenv into the
	//     request URL and flags it. Going through strconv.Atoi ends the taint at
	//     a bounded integer, which is a real sanitisation rather than a
	//     suppression comment — the host stays the hardcoded loopback either way.
	port := 8080
	if v := os.Getenv("PORT"); v != "" {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			os.Exit(1)
		}
		port = p
	}

	// The deadline lives on the context rather than only on http.Client.Timeout:
	// a client timeout does not cancel work already in flight, and `noctx` is
	// enabled precisely so request paths cannot skip cancellation.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	url := fmt.Sprintf("http://127.0.0.1:%d/api/v1/health/live", port)
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
