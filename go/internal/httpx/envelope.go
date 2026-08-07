// Package httpx holds the HTTP response envelope and the request-scoped
// identifiers that every TaskFlow response carries.
//
// The envelope shape is normative — the language-neutral conformance suite
// asserts it byte-for-byte across all five implementations. Do not "improve"
// the field names here without changing the other four services too.
package httpx

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"time"
)

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// TimestampFormat is ISO-8601 with milliseconds and a literal Z suffix.
// The conformance suite rejects anything else.
const TimestampFormat = "2006-01-02T15:04:05.000Z"

type ctxKey int

const (
	ctxKeyRequestID ctxKey = iota
	ctxKeyTraceID
)

// Meta is present on every response, success or error.
//
// requestId is the human-quotable support identifier (^req_[a-zA-Z0-9]+$).
// traceId is 32 lowercase hex, the key into Tempo (OBS4.7).
type Meta struct {
	RequestID string `json:"requestId"`
	Timestamp string `json:"timestamp"`
	TraceID   string `json:"traceId"`
}

// Success is the {success:true, data, meta} envelope.
type Success struct {
	Success bool `json:"success"`
	Data    any  `json:"data"`
	Meta    Meta `json:"meta"`
}

// ErrorBody carries the machine-readable code and the human-readable message.
type ErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

// Error is the {success:false, error, meta} envelope.
type Error struct {
	Success bool      `json:"success"`
	Error   ErrorBody `json:"error"`
	Meta    Meta      `json:"meta"`
}

// NewRequestID returns req_ followed by 12 alphanumeric characters.
func NewRequestID() string {
	b := make([]byte, 12)
	//nolint:errcheck // crypto/rand.Read never returns an error on supported platforms.
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return "req_" + string(b)
}

// newTraceID returns 32 lowercase hex characters.
//
// TODO(Phase 2): delete this. Once the OpenTelemetry SDK is wired up, the
// trace ID must come from the active span context so that meta.traceId
// actually resolves in Tempo. A random value here is a placeholder that keeps
// the envelope shape correct in the meantime.
func newTraceID() string {
	const hexDigits = "0123456789abcdef"
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = hexDigits[int(b[i])%16]
	}
	return string(b)
}

// RequestID middleware stamps every request with a request ID and trace ID and
// echoes the request ID back in the X-Request-Id header.
//
// TODO(Phase 1): honour an inbound X-Request-Id when it is well-formed, so a
// caller can correlate across a retry.
// TODO(Phase 2): extract the W3C traceparent header here instead of minting a
// random trace ID.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := NewRequestID()
		ctx := context.WithValue(r.Context(), ctxKeyRequestID, rid)
		ctx = context.WithValue(ctx, ctxKeyTraceID, newTraceID())
		w.Header().Set("X-Request-Id", rid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequestIDFrom returns the request ID stamped by the RequestID middleware,
// minting a fresh one if the middleware was not in the chain.
func RequestIDFrom(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return NewRequestID()
}

func traceIDFrom(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyTraceID).(string); ok {
		return v
	}
	return newTraceID()
}

// MetaFrom builds the meta object for the current request.
func MetaFrom(ctx context.Context) Meta {
	return Meta{
		RequestID: RequestIDFrom(ctx),
		Timestamp: time.Now().UTC().Format(TimestampFormat),
		TraceID:   traceIDFrom(ctx),
	}
}

// WriteSuccess renders the success envelope.
func WriteSuccess(w http.ResponseWriter, r *http.Request, status int, data any) {
	write(w, status, Success{Success: true, Data: data, Meta: MetaFrom(r.Context())})
}

// WriteError renders the error envelope.
func WriteError(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	WriteErrorDetails(w, r, status, code, message, nil)
}

// WriteErrorDetails renders the error envelope with a details payload —
// field-level validation errors in Phase 1, dependency status on readiness today.
func WriteErrorDetails(w http.ResponseWriter, r *http.Request, status int, code, message string, details any) {
	write(w, status, Error{
		Success: false,
		Error:   ErrorBody{Code: code, Message: message, Details: details},
		Meta:    MetaFrom(r.Context()),
	})
}

// NotImplemented is the placeholder handler mounted on every /api/v1 route
// that has not been built yet. It exists so the conformance suite fails
// loudly and specifically rather than returning a confusing 404.
//
// TODO(Phase 1): as each route is implemented, remove it from the catch-all in
// cmd/server/main.go. When this handler stops being reachable, Phase 1 is done.
func NotImplemented(w http.ResponseWriter, r *http.Request) {
	WriteError(w, r, http.StatusNotImplemented, "NOT_IMPLEMENTED",
		"Not implemented yet — see docs/learning-roadmap.md Phase 1")
}

func write(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	//nolint:errcheck // a failed write means the client is gone; nothing to do.
	_ = json.NewEncoder(w).Encode(body)
}
