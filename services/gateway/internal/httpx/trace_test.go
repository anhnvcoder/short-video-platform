package httpx

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// testTracerProvider is the global tracer provider of the package's tests, with the global
// TraceContext propagator as in the gateway: Trace must ignore a client's traceparent even so.
var testTracerProvider = sdktrace.NewTracerProvider()

// testServer is the server name the tests give Trace.
const testServer = "gateway:8080"

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

// readMetrics makes a meter provider with a manual reader global until the test ends. Handlers
// built after it record there.
func readMetrics(t *testing.T) *sdkmetric.ManualReader {
	t.Helper()
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	return reader
}

// durationPoints returns the data points of http.server.request.duration.
func durationPoints(t *testing.T, reader *sdkmetric.ManualReader) []metricdata.HistogramDataPoint[float64] {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	var points []metricdata.HistogramDataPoint[float64]
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if h, ok := m.Data.(metricdata.Histogram[float64]); ok && m.Name == "http.server.request.duration" {
				points = append(points, h.DataPoints...)
			}
		}
	}
	return points
}

func attrValue(attrs []attribute.KeyValue, key attribute.Key) (string, bool) {
	for _, a := range attrs {
		if a.Key == key {
			return a.Value.String(), true
		}
	}
	return "", false
}

func TestTraceStartsNewRootIgnoringClientContext(t *testing.T) {
	spans := recordSpans(t)
	h := Trace(testServer)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		WriteProblem(w, r, http.StatusNotFound, "NOT_FOUND", "")
	}))
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
	r.Header.Set("Traceparent", clientTraceparent)
	r.Header.Set("Tracestate", "vendor=secret")
	r.Header.Set("Baggage", "user=a@example.com")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)

	ended := spans.Ended()
	if len(ended) != 1 {
		t.Fatalf("spans = %d, want 1", len(ended))
	}
	s := ended[0]
	if s.SpanContext().TraceID().String() == clientTraceID || s.Parent().IsValid() || len(s.Links()) != 0 {
		t.Errorf("span trace %s, parent %v, links %v; want a new root without links", s.SpanContext().TraceID(), s.Parent(), s.Links())
	}
	if ts := s.SpanContext().TraceState().String(); ts != "" {
		t.Errorf("tracestate = %q, want empty", ts)
	}
	if p := decodeProblem(t, rec); p.TraceID != s.SpanContext().TraceID().String() {
		t.Errorf("problem trace_id = %q, want the span's %s", p.TraceID, s.SpanContext().TraceID())
	}
}

func TestTraceClientAddressIsTheConnection(t *testing.T) {
	spans := recordSpans(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
	r.RemoteAddr = "192.0.2.7:4321"
	r.Header.Set("X-Forwarded-For", "a@example.com, 10.0.0.1")
	Trace(testServer)(http.NotFoundHandler()).ServeHTTP(httptest.NewRecorder(), r)
	ended := spans.Ended()
	if len(ended) != 1 {
		t.Fatalf("spans = %d, want 1", len(ended))
	}
	if got, _ := attrValue(ended[0].Attributes(), "client.address"); got != "192.0.2.7" {
		t.Errorf("client.address = %q, want 192.0.2.7 from the connection", got)
	}
}

// TestTraceServerIgnoresHost: server.address and server.port come from the server name, never
// from the Host header the client sets, so a new Host adds no metric series and its value
// reaches neither span nor metric.
func TestTraceServerIgnoresHost(t *testing.T) {
	reader := readMetrics(t)
	spans := recordSpans(t)
	h := Trace(testServer)(http.NotFoundHandler())
	hosts := []string{"attacker-1.example", "attacker-2.example:4444", "user@example.com", "[2001:db8::1]:8443"}
	for _, host := range hosts {
		r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/missing", nil)
		r.Host = host
		h.ServeHTTP(httptest.NewRecorder(), r)
	}

	ended := spans.Ended()
	if len(ended) != len(hosts) {
		t.Fatalf("spans = %d, want %d", len(ended), len(hosts))
	}
	for _, s := range ended {
		address, _ := attrValue(s.Attributes(), "server.address")
		port, _ := attrValue(s.Attributes(), "server.port")
		if address != "gateway" || port != "8080" {
			t.Errorf("span server = %q:%q, want gateway:8080", address, port)
		}
	}
	points := durationPoints(t, reader)
	if len(points) != 1 {
		t.Fatalf("duration series = %d, want 1 whatever the Host", len(points))
	}
	address, _ := points[0].Attributes.Value("server.address")
	port, _ := points[0].Attributes.Value("server.port")
	if address.AsString() != "gateway" || port.AsInt64() != 8080 || points[0].Count != uint64(len(hosts)) {
		t.Errorf("duration series server = %s:%d with %d requests, want gateway:8080 with %d",
			address.AsString(), port.AsInt64(), points[0].Count, len(hosts))
	}
	for _, kv := range points[0].Attributes.ToSlice() {
		for _, part := range []string{"example", "2001:db8", "4444", "8443"} {
			if strings.Contains(kv.Value.String(), part) {
				t.Errorf("metric attribute %s = %q holds a part of a Host header", kv.Key, kv.Value.String())
			}
		}
	}
}

func TestRoutesNameSpanAndMetric(t *testing.T) {
	reader := readMetrics(t)
	spans := recordSpans(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /videos/{video_id}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	h := Trace(testServer)(Routes(mux))
	for _, target := range []string{"/videos/01928c6e-7b3a-7cde-8f01-111111111111", "/nope/42"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil))
	}

	ended := spans.Ended()
	if len(ended) != 2 {
		t.Fatalf("spans = %d, want 2", len(ended))
	}
	if name, _ := attrValue(ended[0].Attributes(), "http.route"); ended[0].Name() != "GET /videos/{video_id}" || name != "/videos/{video_id}" {
		t.Errorf("matched span = %q with http.route %q, want GET /videos/{video_id} and /videos/{video_id}", ended[0].Name(), name)
	}
	if route, has := attrValue(ended[1].Attributes(), "http.route"); ended[1].Name() != "GET" || has {
		t.Errorf("unmatched span = %q with http.route %q, want GET and no route", ended[1].Name(), route)
	}

	var routes []string
	for _, p := range durationPoints(t, reader) {
		route, _ := p.Attributes.Value("http.route")
		code, _ := p.Attributes.Value("http.response.status_code")
		routes = append(routes, fmt.Sprintf("%s %d", route.AsString(), code.AsInt64()))
	}
	slices.Sort(routes)
	if want := []string{" 404", "/videos/{video_id} 204"}; !slices.Equal(routes, want) {
		t.Errorf("duration series = %q, want %q", routes, want)
	}
}

func TestTraceLeavesOutProbes(t *testing.T) {
	reader := readMetrics(t)
	spans := recordSpans(t)
	ran := 0
	h := Trace(testServer)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ran++
		if (r.URL.Path == "/healthz" || r.URL.Path == "/readyz") && traceID(r.Context()) != "" {
			t.Errorf("%s has a trace id", r.URL.Path)
		}
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	for _, path := range []string{"/healthz", "/readyz"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: status %d, want the handler's 503", path, rec.Code)
		}
	}
	if ran != 2 || len(spans.Ended()) != 0 || len(durationPoints(t, reader)) != 0 {
		t.Errorf("handler ran %d times, %d spans, %d metric points; want 2, 0, 0", ran, len(spans.Ended()), len(durationPoints(t, reader)))
	}
	// Only the exact paths are left out.
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/healthz/x", nil))
	if len(spans.Ended()) != 1 {
		t.Errorf("spans = %d after /healthz/x, want 1", len(spans.Ended()))
	}
}

// recordingHandler keeps every record it handles.
type recordingHandler struct {
	mu      sync.Mutex
	records []slog.Record
}

func (*recordingHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *recordingHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, r.Clone())
	return nil
}

func (h *recordingHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *recordingHandler) WithGroup(string) slog.Handler      { return h }

// TestWriteGRPCErrorLogLine: the ERROR line of a 5xx has the route pattern, the gRPC code under
// code and the error as an error value, which the error tracker needs for grouping and for the
// error's type.
func TestWriteGRPCErrorLogLine(t *testing.T) {
	logs := &recordingHandler{}
	prev := slog.Default()
	slog.SetDefault(slog.New(logs))
	t.Cleanup(func() { slog.SetDefault(prev) })

	callErr := fmt.Errorf("get video: %w", status.Error(codes.Unavailable, "connection refused"))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /videos/{video_id}", func(w http.ResponseWriter, r *http.Request) { WriteGRPCError(w, r, callErr) })
	Trace(testServer)(Routes(mux)).ServeHTTP(httptest.NewRecorder(),
		httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/videos/01928c6e-7b3a-7cde-8f01-111111111111", nil))
	// Outside a route.
	WriteGRPCError(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil), callErr)

	if len(logs.records) != 2 {
		t.Fatalf("records = %d, want 2", len(logs.records))
	}
	for i, wantRoute := range []string{"GET /videos/{video_id}", ""} {
		r := logs.records[i]
		attrs := map[string]slog.Value{}
		r.Attrs(func(a slog.Attr) bool {
			attrs[a.Key] = a.Value
			return true
		})
		if r.Level != slog.LevelError || r.Message != "grpc call failed" {
			t.Errorf("record %d = %v %q, want ERROR grpc call failed", i, r.Level, r.Message)
		}
		if attrs["route"].String() != wantRoute || attrs["code"].String() != "Unavailable" {
			t.Errorf("record %d: route %q, code %q; want %q, Unavailable", i, attrs["route"], attrs["code"], wantRoute)
		}
		if err, ok := attrs["error"].Any().(error); attrs["error"].Kind() != slog.KindAny || !ok || !errors.Is(err, callErr) {
			t.Errorf("record %d: error = %#v, want the error value", i, attrs["error"])
		}
		if _, has := attrs["grpc_code"]; has {
			t.Errorf("record %d still has grpc_code", i)
		}
	}
}
