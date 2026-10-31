package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/anhnvcoder/svp-backend/internal/pgpool"
	"github.com/anhnvcoder/svp-backend/internal/sentryx"
)

func TestServeKafkaBrokersMissingOrMalformedNamesTheVariable(t *testing.T) {
	t.Setenv("JWT_SIGNING_KID", "test")
	t.Setenv("JWT_SIGNING_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	// The broker list is checked before the database is opened, so this URL is never dialled.
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	for _, brokers := range []string{"", " , ", "redpanda:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}

// A failure after the error tracker has started is logged while the tracker still runs, so that
// it reaches the tracker, and only once: main does not log it again.
func TestServeReportsAFailureBeforeTheErrorTrackerStops(t *testing.T) {
	var mu sync.Mutex
	var envelopes []string
	tracker := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		envelopes = append(envelopes, string(body))
		mu.Unlock()
	}))
	defer tracker.Close()
	t.Setenv("SENTRY_DSN", "http://public@"+tracker.Listener.Addr().String()+"/1")
	t.Setenv("OTEL_SDK_DISABLED", "true")
	t.Setenv("JWT_SIGNING_KID", "test")
	t.Setenv("JWT_SIGNING_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	t.Setenv("KAFKA_BROKERS", "redpanda:9092")
	// pgpool rejects this URL once the tracker has started. Every later failure, a malformed
	// LISTEN_ADDR included, returns through the same deferred call.
	t.Setenv("DATABASE_URL", "postgres://%zz")
	var logs bytes.Buffer
	logger := slog.New(slog.NewMultiHandler(slog.NewJSONHandler(&logs, nil), &sentryx.Handler{}))

	err := serve(t.Context(), logger)
	if _, logged := errors.AsType[loggedError](err); !logged || !errors.Is(err, pgpool.ErrInvalidURL) {
		t.Fatalf("serve() = %v, want a loggedError wrapping pgpool.ErrInvalidURL", err)
	}
	if n := strings.Count(logs.String(), `"msg":"user-service failed"`); n != 1 {
		t.Errorf("logged the failure %d times, want 1; log:\n%s", n, logs.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.ContainsFunc(envelopes, func(e string) bool { return strings.Contains(e, `"message":"user-service failed"`) }) {
		t.Errorf("tracker received %q, want an event for the failure", envelopes)
	}
}
