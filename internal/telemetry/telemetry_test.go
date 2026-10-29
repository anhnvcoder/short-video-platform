package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

func setupEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{"OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_ENDPOINT", "PYROSCOPE_SERVER_ADDRESS",
		"PYROSCOPE_ADHOC_SERVER_ADDRESS", "OTEL_TRACES_SAMPLER", "OTEL_TRACES_SAMPLER_ARG",
		"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"} {
		t.Setenv(name, "")
	}
	// Pyroscope treats even an empty adhoc override as an address override.
	if err := os.Unsetenv("PYROSCOPE_ADHOC_SERVER_ADDRESS"); err != nil {
		t.Fatal(err)
	}
	tp, mp, lp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetLoggerProvider()
	prop, eh := otel.GetTextMapPropagator(), otel.GetErrorHandler()
	logger := slog.Default()
	t.Cleanup(func() {
		if otel.GetTracerProvider() != tp {
			otel.SetTracerProvider(tp)
		}
		if otel.GetMeterProvider() != mp {
			otel.SetMeterProvider(mp)
		}
		if otel.GetLoggerProvider() != lp {
			otel.SetLoggerProvider(lp)
		}
		if otel.GetTextMapPropagator() != prop {
			otel.SetTextMapPropagator(prop)
		}
		if _, changed := otel.GetErrorHandler().(*errorHandler); changed {
			otel.SetErrorHandler(eh)
		}
		slog.SetDefault(logger)
	})
}

func TestSetupWithoutEndpoint(t *testing.T) {
	for _, unset := range []bool{false, true} {
		name := "empty"
		if unset {
			name = "unset"
		}
		t.Run(name, func(t *testing.T) {
			setupEnv(t)
			if unset {
				if err := os.Unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"); err != nil {
					t.Fatal(err)
				}
			}
			// Signal-specific endpoints must not bypass the common endpoint guard.
			for _, signal := range []string{"TRACES", "METRICS", "LOGS"} {
				t.Setenv("OTEL_EXPORTER_OTLP_"+signal+"_ENDPOINT", "://invalid")
			}
			shutdown, err := Setup(context.Background(), "test-service")
			if err != nil {
				t.Fatal(err)
			}
			tp := otel.GetTracerProvider().(*sdktrace.TracerProvider)
			recorder := tracetest.NewSpanRecorder()
			tp.RegisterSpanProcessor(recorder)
			ctx, span := otel.Tracer("test").Start(context.Background(), "work")
			if !span.SpanContext().IsValid() || !span.IsRecording() {
				t.Fatal("provider without exporter must still generate recording span context")
			}
			carrier := propagation.MapCarrier{}
			otel.GetTextMapPropagator().Inject(ctx, carrier)
			if carrier.Get("traceparent") == "" || slices.Contains(otel.GetTextMapPropagator().Fields(), "baggage") {
				t.Fatalf("unexpected propagation: %v", carrier)
			}
			span.End()
			attrs := recorder.Ended()[0].Resource().Set()
			service, _ := attrs.Value(attribute.Key("service.name"))
			instance, _ := attrs.Value(attribute.Key("service.instance.id"))
			if service.AsString() != "test-service" || instance.AsString() == "" {
				t.Fatalf("unexpected resource: %v", attrs)
			}
			if err := tp.ForceFlush(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := otel.GetMeterProvider().(*sdkmetric.MeterProvider).ForceFlush(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := otel.GetLoggerProvider().(*sdklog.LoggerProvider).ForceFlush(context.Background()); err != nil {
				t.Fatal(err)
			}
			if err := shutdown(context.Background()); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSetupDisabled(t *testing.T) {
	setupEnv(t)
	t.Setenv("OTEL_SDK_DISABLED", "true")
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "://invalid")
	t.Setenv("PYROSCOPE_SERVER_ADDRESS", "://invalid")
	tp, mp, lp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetLoggerProvider()
	shutdown, err := Setup(context.Background(), "disabled")
	if err != nil {
		t.Fatal(err)
	}
	if tp != otel.GetTracerProvider() || mp != otel.GetMeterProvider() || lp != otel.GetLoggerProvider() {
		t.Fatal("disabled setup changed global providers")
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestSetupUnavailableCollectorDoesNotBlock(t *testing.T) {
	setupEnv(t)
	lc := net.ListenConfig{}
	listener, err := lc.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+address)
	t.Setenv("OTEL_EXPORTER_OTLP_INSECURE", "true")
	slog.SetDefault(slog.New(slog.NewJSONHandler(io.Discard, nil)))
	start := time.Now()
	shutdown, err := Setup(context.Background(), "unavailable")
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed >= time.Second {
		t.Errorf("setup took %s, want < 1s", elapsed)
	}
	logger := slog.New(otelslog.NewHandler("test"))
	counter, err := otel.Meter("test").Int64Counter("test.requests")
	if err != nil {
		t.Fatal(err)
	}
	// Exceed both queues to exercise their non-blocking overflow behavior as well. An export to
	// the closed port runs until the export timeout, so a call that waited on an export would take
	// at least exportTimeout. A non-blocking call takes microseconds; even on a loaded machine
	// under -race, all 3000 iterations together have taken well under half a second. Checking
	// the slowest single iteration against a fifth of the export timeout keeps both cases apart
	// whatever the machine's speed.
	var slowest time.Duration
	for range 3000 {
		start = time.Now()
		ctx, span := otel.Tracer("test").Start(context.Background(), "request")
		logger.InfoContext(ctx, "request")
		counter.Add(ctx, 1)
		span.End()
		slowest = max(slowest, time.Since(start))
	}
	if limit := exportTimeout / 5; slowest >= limit {
		t.Errorf("slowest span/log/metric iteration took %s, want < %s (a blocked call waits up to %s)",
			slowest, limit, exportTimeout)
	}
	start = time.Now()
	err = shutdown(context.Background())
	if elapsed := time.Since(start); elapsed > 5500*time.Millisecond {
		t.Errorf("shutdown took %s, want <= 5.5s", elapsed)
	}
	if err == nil {
		t.Error("shutdown should report unavailable collector")
	}
	if again := shutdown(context.Background()); !errors.Is(again, context.DeadlineExceeded) {
		t.Errorf("repeated shutdown = %v, want original deadline error", again)
	}
}

func TestTracerProviderExportsAndReadsSampler(t *testing.T) {
	for _, sampler := range []string{"", "always_off", "traceidratio", "parentbased_always_on"} {
		t.Run(sampler, func(t *testing.T) {
			t.Setenv("OTEL_TRACES_SAMPLER", sampler)
			t.Setenv("OTEL_TRACES_SAMPLER_ARG", "0")
			exporter := tracetest.NewInMemoryExporter()
			tp := newTracerProvider(resource.Empty(), exporter)
			_, span := tp.Tracer("test").Start(context.Background(), "work")
			sc := span.SpanContext()
			span.End()
			if err := tp.ForceFlush(context.Background()); err != nil {
				t.Fatal(err)
			}
			want := 1
			if sampler == "always_off" || sampler == "traceidratio" {
				want = 0
			}
			spans := exporter.GetSpans()
			if len(spans) != want || !sc.IsValid() {
				t.Fatalf("exported %d spans, want %d; context = %v", len(spans), want, sc)
			}
			if want == 1 && !spans[0].SpanContext.Equal(sc) {
				t.Error("exported span context differs")
			}
			// Default sampling respects an unsampled remote parent.
			parent := trace.NewSpanContext(trace.SpanContextConfig{TraceID: sc.TraceID(), SpanID: sc.SpanID(), Remote: true})
			_, child := tp.Tracer("test").Start(trace.ContextWithRemoteSpanContext(context.Background(), parent), "child")
			if (sampler == "" || sampler == "parentbased_always_on") && child.SpanContext().IsSampled() {
				t.Error("parent-based sampler sampled an unsampled parent's child")
			}
			child.End()
			if err := tp.Shutdown(context.Background()); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestDurationViewsAndRuntimeMetrics(t *testing.T) {
	reader := sdkmetric.NewManualReader()
	mp := newMeterProvider(resource.Empty(), reader)
	defer func() {
		if err := mp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	}()
	if err := runtime.Start(runtime.WithMeterProvider(mp)); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"http.server.request.duration", "rpc.server.call.duration", "rpc.client.call.duration"} {
		h, err := mp.Meter("test").Float64Histogram(name, metric.WithUnit("s"))
		if err != nil {
			t.Fatal(err)
		}
		h.Record(context.Background(), 0.14)
	}
	var data metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &data); err != nil {
		t.Fatal(err)
	}
	want := []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5, 10}
	histograms, runtimeFound := 0, false
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name == "go.goroutine.count" {
				runtimeFound = true
			}
			if h, ok := m.Data.(metricdata.Histogram[float64]); ok {
				histograms++
				point := h.DataPoints[0]
				if !slices.Equal(point.Bounds, want) || point.Count != 1 || point.BucketCounts[5] != 1 {
					t.Errorf("%s: unexpected histogram %v", m.Name, point)
				}
			}
		}
	}
	if histograms != 3 || !runtimeFound {
		t.Fatalf("histograms = %d, runtime found = %v", histograms, runtimeFound)
	}
}

func TestLoopReportsZeroAndLastSuccessOnEveryCollection(t *testing.T) {
	setupEnv(t)
	reader := sdkmetric.NewManualReader()
	mp := newMeterProvider(resource.Empty(), reader)
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		if err := mp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	l := NewLoop("outbox-relay")
	NewLoop("upload-sweep")
	collect := func() map[string]metricdata.DataPoint[int64] {
		t.Helper()
		var data metricdata.ResourceMetrics
		if err := reader.Collect(context.Background(), &data); err != nil {
			t.Fatal(err)
		}
		points := map[string]metricdata.DataPoint[int64]{}
		for _, scope := range data.ScopeMetrics {
			for _, m := range scope.Metrics {
				if m.Name != "svp.loop.last_success" || m.Unit != "s" {
					t.Fatalf("unexpected metric %v", m)
				}
				for _, p := range m.Data.(metricdata.Gauge[int64]).DataPoints {
					label, _ := p.Attributes.Value(attribute.Key("loop"))
					if p.Attributes.Len() != 1 {
						t.Errorf("unexpected labels: %v", p.Attributes)
					}
					points[label.AsString()] = p
				}
			}
		}
		return points
	}
	initial := collect()
	if len(initial) != 2 || initial["outbox-relay"].Value != 0 || initial["upload-sweep"].Value != 0 {
		t.Fatalf("initial loop values = %v", initial)
	}
	before := time.Now().Unix()
	var wg sync.WaitGroup
	for range 10 {
		wg.Go(l.Succeeded)
	}
	wg.Wait()
	first := collect()["outbox-relay"]
	if first.Value < before || first.Value > time.Now().Unix() {
		t.Fatalf("last success = %d, want current Unix seconds", first.Value)
	}
	second := collect()
	if second["outbox-relay"].Value != first.Value || !second["outbox-relay"].Time.After(first.Time) || second["upload-sweep"].Value != 0 {
		t.Fatalf("unchanged timestamps were not freshly observed: %v", second)
	}
}

func TestExportErrorsAreRateLimited(t *testing.T) {
	var buf bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	defer slog.SetDefault(previous)
	now := time.Unix(100, 0)
	h := newErrorHandler(func() time.Time { return now })
	h.Handle(errors.New("collector unavailable"))
	for range 10 {
		h.Handle(errors.New("collector unavailable"))
	}
	now = now.Add(time.Minute - time.Nanosecond)
	h.Handle(errors.New("collector unavailable"))
	if bytes.Count(buf.Bytes(), []byte("\n")) != 1 {
		t.Fatalf("expected one warning before minute boundary: %s", buf.String())
	}
	now = now.Add(time.Nanosecond)
	h.Handle(errors.New("collector unavailable"))
	decoder := json.NewDecoder(&buf)
	for _, want := range []float64{0, 11} {
		var record map[string]any
		if err := decoder.Decode(&record); err != nil {
			t.Fatal(err)
		}
		if record["level"] != "WARN" || record["suppressed"] != want {
			t.Errorf("unexpected warning: %v", record)
		}
	}
	if decoder.More() {
		t.Fatal("unexpected extra warnings")
	}
}

func TestStopAllSharesDeadline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := make(chan time.Time, 4)
	stop := func(ctx context.Context) error {
		deadline, _ := ctx.Deadline()
		started <- deadline
		<-ctx.Done()
		return ctx.Err()
	}
	start := time.Now()
	if err := stopAll(ctx, []func(context.Context) error{stop, stop, stop, stop}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown = %v, want deadline exceeded", err)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("shutdown exceeded shared budget")
	}
	want, _ := ctx.Deadline()
	for range 4 {
		if got := <-started; !got.Equal(want) {
			t.Errorf("deadline = %v, want %v", got, want)
		}
	}
}

func TestProfilerClientKeepsBodyReadableAndCancelsUploads(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("profile accepted"))
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := &profileClient{ctx: ctx, client: server.Client()}
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	if closeErr := response.Body.Close(); closeErr != nil {
		t.Fatal(closeErr)
	}
	if err != nil || string(body) != "profile accepted" {
		t.Fatalf("response body = %q, error = %v", body, err)
	}
	cancel()
	if response, err := client.Do(req); !errors.Is(err, context.Canceled) {
		if response != nil {
			_ = response.Body.Close()
		}
		t.Fatalf("canceled upload = %v", err)
	}
}

func TestSetupProfilerShutdown(t *testing.T) {
	setupEnv(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	t.Setenv("PYROSCOPE_SERVER_ADDRESS", server.URL)
	// A second lifecycle also verifies the first shutdown released the CPU profiler.
	for range 2 {
		shutdown, err := Setup(context.Background(), "profile-test")
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		if err := shutdown(context.Background()); err != nil {
			t.Fatal(err)
		}
		if elapsed := time.Since(start); elapsed > 5500*time.Millisecond {
			t.Fatalf("profiler shutdown took %s, want <= 5.5s", elapsed)
		}
	}
}
