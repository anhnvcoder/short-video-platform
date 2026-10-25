package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"go.opentelemetry.io/otel"

	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
)

// TestNoPprofOnDefaultMux is threat model OPS-1: no package of the gateway registers
// net/http/pprof, whose import alone would serve it on http.DefaultServeMux.
func TestNoPprofOnDefaultMux(t *testing.T) {
	for _, path := range []string{"/debug/pprof/", "/debug/pprof/heap"} {
		_, pattern := http.DefaultServeMux.Handler(httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
		if pattern != "" {
			t.Errorf("%s is served by http.DefaultServeMux (%q)", path, pattern)
		}
	}
}

// TestHealthcheckStartsNoTelemetry: the healthcheck subcommand, which a container runtime runs
// every few seconds, installs no OTel provider and starts no error reporting even with the
// endpoints and SENTRY_DSN set.
func TestHealthcheckStartsNoTelemetry(t *testing.T) {
	var lc net.ListenConfig
	lis, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := lis.Addr().String()
	if err := lis.Close(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LISTEN_ADDR", addr)
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+addr)
	t.Setenv("SENTRY_DSN", "http://public@"+addr+"/1")
	tp, mp, lp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetLoggerProvider()
	probe := &reportingProbe{}
	if err := run(t.Context(), slog.New(probe), "healthcheck"); err == nil {
		t.Fatal("healthcheck of a closed port succeeded")
	}
	if otel.GetTracerProvider() != tp || otel.GetMeterProvider() != mp || otel.GetLoggerProvider() != lp {
		t.Error("healthcheck installed an OTel provider")
	}
	if probe.errors != 1 || probe.reporting != 0 {
		t.Errorf("healthcheck logged %d errors, %d of them while error reporting was on; want 1 and 0", probe.errors, probe.reporting)
	}
	if (&sentryx.Handler{}).Enabled(t.Context(), slog.LevelError) {
		t.Error("healthcheck left error reporting on")
	}
}

// reportingProbe counts the ERROR records it gets, and those logged while sentryx reports errors.
type reportingProbe struct{ errors, reporting int }

func (*reportingProbe) Enabled(context.Context, slog.Level) bool { return true }

func (p *reportingProbe) Handle(ctx context.Context, r slog.Record) error {
	if r.Level >= slog.LevelError {
		p.errors++
		if (&sentryx.Handler{}).Enabled(ctx, r.Level) {
			p.reporting++
		}
	}
	return nil
}

func (p *reportingProbe) WithAttrs([]slog.Attr) slog.Handler { return p }
func (p *reportingProbe) WithGroup(string) slog.Handler      { return p }

// TestServeFailureReachesErrorTracker: a failure that stops serve is logged before the error
// tracker is flushed and closed, so the tracker receives it.
func TestServeFailureReachesErrorTracker(t *testing.T) {
	var mu sync.Mutex
	var events []string
	tracker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		events = append(events, string(body))
		mu.Unlock()
	}))
	t.Cleanup(tracker.Close)
	t.Setenv("SENTRY_DSN", "http://public@"+strings.TrimPrefix(tracker.URL, "http://")+"/1")
	// The providers would stay global for the package's other tests.
	t.Setenv("OTEL_SDK_DISABLED", "true")
	// serve fails at once, before it dials or listens.
	t.Setenv("JWT_VERIFY_KEYS", "")

	if err := run(t.Context(), slog.New(&sentryx.Handler{}), "serve"); err == nil {
		t.Fatal("serve without JWT_VERIFY_KEYS succeeded")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(events) != 1 || !strings.Contains(events[0], `"service":"gateway"`) || !strings.Contains(events[0], "*errors.errorString") ||
		!strings.Contains(events[0], `"message":"gateway failed"`) {
		t.Errorf("tracker received %q, want one event of the gateway with its message and the error's type", events)
	}
}
