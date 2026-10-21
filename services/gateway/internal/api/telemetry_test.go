package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
)

// testTracerProvider and the TraceContext propagator are global in the package's tests, as
// telemetry.Setup makes them in the gateway.
var testTracerProvider = sdktrace.NewTracerProvider()

func TestMain(m *testing.M) {
	otel.SetTracerProvider(testTracerProvider)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	os.Exit(m.Run())
}

// recordSpans returns a recorder of the spans that end until the test ends.
func recordSpans(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	rec := tracetest.NewSpanRecorder()
	testTracerProvider.RegisterSpanProcessor(rec)
	t.Cleanup(func() { testTracerProvider.UnregisterSpanProcessor(rec) })
	return rec
}

// logLines returns the decoded log lines whose msg is msg.
func logLines(t *testing.T, logs *bytes.Buffer, msg string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for line := range bytes.Lines(logs.Bytes()) {
		var rec map[string]any
		if err := json.Unmarshal(line, &rec); err != nil {
			t.Fatalf("log line %q is not JSON: %v", line, err)
		}
		if rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

// TestTraceAcrossServices: the HTTP span, the gRPC client span and the span of the service form
// one new trace, whatever traceparent the client sent; the problem body, the access log and the
// ERROR line all name that trace.
func TestTraceAcrossServices(t *testing.T) {
	logs := captureLog(t)
	spans := recordSpans(t)
	e := newEnv(t)
	e.videos.fail(status.Error(codes.Unavailable, "db down"))
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/videos/"+videoID, nil)
	r.Header.Set("Authorization", "Bearer "+e.token(t, userA))
	r.Header.Set("Traceparent", clientTraceparent)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusServiceUnavailable)

	var httpSpan, clientSpan, serverSpan sdktrace.ReadOnlySpan
	for _, s := range spans.Ended() {
		switch {
		case s.SpanKind() == trace.SpanKindServer && s.Name() == "GET /videos/{video_id}":
			httpSpan = s
		case s.SpanKind() == trace.SpanKindClient:
			clientSpan = s
		case s.SpanKind() == trace.SpanKindServer && s.Name() == strings.TrimPrefix(videov1.VideoService_GetVideo_FullMethodName, "/"):
			serverSpan = s
		}
	}
	if httpSpan == nil || clientSpan == nil || serverSpan == nil {
		t.Fatalf("spans = %v, want the HTTP, gRPC client and service spans", spanNames(spans.Ended()))
	}
	id := httpSpan.SpanContext().TraceID()
	if id.String() == clientTraceID || httpSpan.Parent().IsValid() {
		t.Errorf("HTTP span trace %s, parent %v; want a new root", id, httpSpan.Parent())
	}
	if clientSpan.Parent().SpanID() != httpSpan.SpanContext().SpanID() || clientSpan.SpanContext().TraceID() != id {
		t.Errorf("client span is not a child of the HTTP span")
	}
	if serverSpan.Parent().SpanID() != clientSpan.SpanContext().SpanID() || serverSpan.SpanContext().TraceID() != id {
		t.Errorf("service span is not a child of the client span")
	}

	if p := decodeProblem(t, rec); p.TraceID != id.String() {
		t.Errorf("problem trace_id = %s, want %s", p.TraceID, id)
	}
	access := logLines(t, logs, "http request")
	failed := logLines(t, logs, "grpc call failed")
	if len(access) != 1 || access[0]["trace_id"] != id.String() || access[0]["span_id"] != httpSpan.SpanContext().SpanID().String() {
		t.Errorf("access log = %v, want trace_id %s and the HTTP span's span_id", access, id)
	}
	if len(failed) != 1 || failed[0]["trace_id"] != id.String() || failed[0]["route"] != "GET /videos/{video_id}" || failed[0]["code"] != "Unavailable" {
		t.Errorf("ERROR line = %v, want trace_id %s, route and code", failed, id)
	}
}

func spanNames(spans []sdktrace.ReadOnlySpan) []string {
	names := make([]string, len(spans))
	for i, s := range spans {
		names[i] = s.SpanKind().String() + " " + s.Name()
	}
	return names
}

// TestLoginSpansHoldNoSecrets: whether the login succeeds or not, no span holds the email, the
// password, a token or a header.
func TestLoginSpansHoldNoSecrets(t *testing.T) {
	const email, password, bearer = "login.secret@example.com", "correct horse battery", "eyJhbGciOi.client.token" //nolint:gosec // fake credentials are the case under test
	for _, tc := range []struct {
		name string
		fail error
		want int
	}{
		{"success", nil, http.StatusOK},
		{"wrong password", grpcerr.New(codes.Unauthenticated, "INVALID_CREDENTIALS", "invalid email or password"), http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			captureLog(t)
			spans := recordSpans(t)
			e := newEnv(t)
			if tc.fail != nil {
				e.users.fail(tc.fail)
			}
			r := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/auth/login",
				strings.NewReader(`{"email":"`+email+`","password":"`+password+`"}`))
			r.Header.Set("Content-Type", "application/json")
			r.Header.Set("Authorization", "Bearer "+bearer)
			r.Header.Set("Cookie", "session="+bearer)
			r.Header.Set("X-Forwarded-For", email)
			rec := httptest.NewRecorder()
			e.handler.ServeHTTP(rec, r)
			wantStatus(t, rec, tc.want)

			ended := spans.Ended()
			if len(ended) != 3 {
				t.Fatalf("spans = %v, want HTTP, client and service", spanNames(ended))
			}
			raw, err := json.Marshal(tracetest.SpanStubsFromReadOnlySpans(ended))
			if err != nil {
				t.Fatal(err)
			}
			for _, secret := range []string{email, password, bearer, fakeAccessToken, "Authorization", "authorization", "session="} {
				if bytes.Contains(raw, []byte(secret)) {
					t.Errorf("spans contain %q:\n%s", secret, raw)
				}
			}
			if !bytes.Contains(raw, []byte(`"POST /auth/login"`)) {
				t.Errorf("no span named POST /auth/login:\n%s", raw)
			}
		})
	}
}

// TestRefreshTokensStayOutOfTelemetry is threat model JWT-8 on refresh and logout: whatever
// user-service answers, neither the presented refresh token nor the tokens of the answer reach a
// span, a log line or a problem body.
func TestRefreshTokensStayOutOfTelemetry(t *testing.T) {
	for _, tc := range []struct {
		name, path string
		fail       error
		want       int
	}{
		{"refresh", "/auth/refresh", nil, http.StatusOK},
		{"refresh with an invalid token", "/auth/refresh", grpcerr.New(codes.Unauthenticated, "INVALID_REFRESH_TOKEN", "invalid refresh token"), http.StatusUnauthorized},
		{"refresh failing inside user-service", "/auth/refresh", grpcerr.New(codes.Internal, "DB_DOWN", "database unavailable"), http.StatusInternalServerError},
		{"logout", "/auth/logout", nil, http.StatusNoContent},
		{"logout with user-service unavailable", "/auth/logout", status.Error(codes.Unavailable, "user-service is down"), http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logs := captureLog(t)
			spans := recordSpans(t)
			e := newEnv(t)
			if tc.fail != nil {
				e.users.fail(tc.fail)
			}
			rec := e.do(t, http.MethodPost, tc.path, refreshBody, "")
			wantStatus(t, rec, tc.want)
			if strings.Contains(rec.Body.String(), fakeRefreshToken) {
				t.Errorf("response echoes the presented token: %s", rec.Body.String())
			}

			ended := spans.Ended()
			if len(ended) != 3 {
				t.Fatalf("spans = %v, want HTTP, client and service", spanNames(ended))
			}
			raw, err := json.Marshal(tracetest.SpanStubsFromReadOnlySpans(ended))
			if err != nil {
				t.Fatal(err)
			}
			for _, secret := range []string{fakeRefreshToken, rotatedRefreshToken, rotatedAccessToken} {
				if bytes.Contains(raw, []byte(secret)) {
					t.Errorf("spans contain %q:\n%s", secret, raw)
				}
				if strings.Contains(logs.String(), secret) {
					t.Errorf("log contains %q:\n%s", secret, logs.String())
				}
			}
			if access := logLines(t, logs, "http request"); len(access) != 1 || access[0]["route"] != "POST "+tc.path {
				t.Errorf("access log = %v, want one line for POST %s", access, tc.path)
			}
		})
	}
}

// TestLoginWithUserServiceDown: a 503 from login is an ERROR line with the trace, the route and
// the code, which the error tracker receives, and without the email.
func TestLoginWithUserServiceDown(t *testing.T) {
	logs := captureLog(t)
	e := newEnv(t)
	e.users.stop()
	rec := e.do(t, http.MethodPost, "/auth/login", `{"email":"down.user@example.com","password":"correct horse"}`, "")
	wantStatus(t, rec, http.StatusServiceUnavailable)
	p := decodeProblem(t, rec)
	failed := logLines(t, logs, "grpc call failed")
	if len(failed) != 1 || failed[0]["level"] != "ERROR" || failed[0]["trace_id"] != p.TraceID ||
		failed[0]["route"] != "POST /auth/login" || failed[0]["code"] != "Unavailable" {
		t.Errorf("ERROR line = %v, want trace_id %s, route POST /auth/login, code Unavailable", failed, p.TraceID)
	}
	if strings.Contains(logs.String(), "down.user@example.com") {
		t.Errorf("log contains the email:\n%s", logs)
	}
	if got := len(e.users.recorded()); got != 0 {
		t.Errorf("user-service got %d calls, want 0", got)
	}
}

// TestReadyzLeavesNoSpans: /readyz, which a container runtime calls every few seconds, gives
// neither an HTTP span nor client spans for its health checks (docs/adr/0011-observability-stage3.md,
// sections 3 and 10). The fake services trace every RPC they serve, so their spans show that the
// checks were made, without a trace from the gateway.
func TestReadyzLeavesNoSpans(t *testing.T) {
	spans := recordSpans(t)
	e := newEnv(t)
	wantStatus(t, e.do(t, http.MethodGet, "/readyz", "", ""), http.StatusOK)

	checks := 0
	for _, s := range spans.Ended() {
		switch {
		case s.SpanKind() == trace.SpanKindServer && s.Name() == strings.TrimPrefix(healthpb.Health_Check_FullMethodName, "/"):
			checks++
			if s.Parent().IsValid() {
				t.Errorf("health check span has the parent %s, want none", s.Parent().SpanID())
			}
		default:
			t.Errorf("span %s %q, want none from the gateway", s.SpanKind(), s.Name())
		}
	}
	if checks != 3 {
		t.Errorf("health check spans of the services = %d, want 3", checks)
	}
}

// TestNoProfilingOrMetricsRoutes is threat model OPS-1: no pprof and no /metrics on the API.
func TestNoProfilingOrMetricsRoutes(t *testing.T) {
	e := newEnv(t)
	for _, path := range []string{"/debug/pprof/", "/debug/pprof/heap", "/debug/pprof/cmdline", "/metrics"} {
		rec := e.do(t, http.MethodGet, path, "", e.token(t, userA))
		wantStatus(t, rec, http.StatusNotFound)
		if p := decodeProblem(t, rec); p.Code != "NOT_FOUND" {
			t.Errorf("%s: code = %q, want NOT_FOUND", path, p.Code)
		}
	}
	// Nothing linked into this package registers net/http/pprof on the default mux either.
	_, pattern := http.DefaultServeMux.Handler(httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/debug/pprof/", nil))
	if pattern != "" {
		t.Errorf("http.DefaultServeMux serves %q", pattern)
	}
}

// TestUnreachableTelemetryDoesNotSlowRequests: with the Collector and the error tracker on a
// closed port, failing requests (each an ERROR line, so an error event) take no longer than with
// telemetry off.
func TestUnreachableTelemetryDoesNotSlowRequests(t *testing.T) {
	const requests = 50
	prevLogger := slog.Default()
	// The gateway's logger, writing nowhere: logx.New writes to stdout.
	slog.SetDefault(slog.New(logx.NewHandler(slog.NewMultiHandler(
		slog.NewJSONHandler(io.Discard, nil), otelslog.NewHandler("gateway"), &sentryx.Handler{},
	))))
	t.Cleanup(func() { slog.SetDefault(prevLogger) })
	run := func() time.Duration {
		e := newEnv(t)
		e.videos.fail(status.Error(codes.Unavailable, "db down"))
		token := e.token(t, userA)
		start := time.Now()
		for range requests {
			wantStatus(t, e.do(t, http.MethodGet, "/videos/"+videoID, "", token), http.StatusServiceUnavailable)
		}
		return time.Since(start)
	}
	for _, name := range []string{"OTEL_SDK_DISABLED", "OTEL_TRACES_SAMPLER", "OTEL_TRACES_SAMPLER_ARG", "PYROSCOPE_SERVER_ADDRESS",
		"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"} {
		t.Setenv(name, "")
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
	t.Setenv("SENTRY_DSN", "")
	off := run()

	var lc net.ListenConfig
	lis, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := lis.Addr().String()
	if err := lis.Close(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+addr)
	t.Setenv("OTEL_EXPORTER_OTLP_INSECURE", "true")
	t.Setenv("SENTRY_DSN", "http://public@"+addr+"/1")
	tp, mp, lp, prop, eh := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetLoggerProvider(), otel.GetTextMapPropagator(), otel.GetErrorHandler()
	flush, err := sentryx.Init("gateway")
	if err != nil {
		t.Fatal(err)
	}
	shutdown, err := telemetry.Setup(t.Context(), "gateway")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		defer cancel()
		_ = shutdown(ctx) // the Collector is unreachable
		flush()
		otel.SetTracerProvider(tp)
		otel.SetMeterProvider(mp)
		otel.SetLoggerProvider(lp)
		otel.SetTextMapPropagator(prop)
		otel.SetErrorHandler(eh)
	})
	on := run()
	if on > 2*off+200*time.Millisecond {
		t.Errorf("%d requests took %v with telemetry unreachable, %v with it off", requests, on, off)
	}
	t.Logf("%d requests: telemetry off %v, unreachable %v", requests, off, on)
}
