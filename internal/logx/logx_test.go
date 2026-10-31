package logx

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	collectorlog "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	"google.golang.org/grpc"

	"github.com/anhnvcoder/svp-backend/internal/telemetry"
)

func decode(t *testing.T, buf *bytes.Buffer) map[string]any {
	t.Helper()
	var rec map[string]any
	if err := json.Unmarshal(buf.Bytes(), &rec); err != nil {
		t.Fatalf("log output %q is not one JSON object: %v", buf.String(), err)
	}
	return rec
}

func TestLoggerAddsServiceAndContextAttrs(t *testing.T) {
	var buf bytes.Buffer
	logger := newLogger(&buf, "user-service")

	ctx := With(context.Background(), slog.String("trace_id", "4bf92f3577b34da6a3ce929d0e0e4736"))
	sc := trace.NewSpanContext(trace.SpanContextConfig{TraceID: trace.TraceID{1}, SpanID: trace.SpanID{2}})
	ctx = trace.ContextWithSpanContext(ctx, sc)
	ctx = With(ctx, slog.String("user_id", "0192f0c4-0000-7000-8000-000000000001"))
	logger.InfoContext(ctx, "rpc", slog.String("method", "/svp.user.v1.UserService/Login"))

	rec := decode(t, &buf)
	want := map[string]string{
		"msg":      "rpc",
		"service":  "user-service",
		"method":   "/svp.user.v1.UserService/Login",
		"trace_id": sc.TraceID().String(),
		"span_id":  sc.SpanID().String(),
		"user_id":  "0192f0c4-0000-7000-8000-000000000001",
	}
	for k, v := range want {
		if rec[k] != v {
			t.Errorf("%s = %v, want %q", k, rec[k], v)
		}
	}
}

func TestLoggerWithoutContextAttrs(t *testing.T) {
	var buf bytes.Buffer
	newLogger(&buf, "gateway").InfoContext(context.Background(), "started")

	rec := decode(t, &buf)
	if _, ok := rec["trace_id"]; ok {
		t.Errorf("trace_id present without context attrs: %v", rec)
	}
	if _, ok := rec["span_id"]; ok {
		t.Errorf("span_id present without span context: %v", rec)
	}
	if rec["service"] != "gateway" {
		t.Errorf("service = %v, want gateway", rec["service"])
	}
}

func TestLoggerTraceAttrsPreferValidSpanContext(t *testing.T) {
	attrs := []slog.Attr{slog.String("trace_id", "legacy-trace"), slog.String("span_id", "legacy-span")}
	tests := []struct {
		name    string
		log     func(*slog.Logger, context.Context)
		grouped bool
	}{
		{name: "record", log: func(logger *slog.Logger, ctx context.Context) {
			logger.LogAttrs(ctx, slog.LevelInfo, "request", attrs...)
		}},
		{name: "context", log: func(logger *slog.Logger, ctx context.Context) {
			logger.InfoContext(With(ctx, attrs...), "request")
		}},
		{name: "bound", log: func(logger *slog.Logger, ctx context.Context) {
			logger.With(attrs[0]).With(attrs[1]).InfoContext(ctx, "request")
		}},
		{name: "bound_group", grouped: true, log: func(logger *slog.Logger, ctx context.Context) {
			logger.WithGroup("request").With(attrs[0]).With(attrs[1]).InfoContext(ctx, "request")
		}},
	}
	contexts := []struct {
		name string
		sc   trace.SpanContext
	}{
		{name: "no_span"},
		{name: "invalid_span", sc: trace.NewSpanContext(trace.SpanContextConfig{TraceID: trace.TraceID{1}})},
		{name: "valid_span", sc: trace.NewSpanContext(trace.SpanContextConfig{TraceID: trace.TraceID{1}, SpanID: trace.SpanID{2}})},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger := newLogger(&buf, "svc")
			for _, tc := range contexts {
				t.Run(tc.name, func(t *testing.T) {
					buf.Reset()
					ctx := trace.ContextWithSpanContext(context.Background(), tc.sc)
					tt.log(logger, ctx)
					rec := decode(t, &buf)
					if tt.grouped {
						group, ok := rec["request"].(map[string]any)
						if !ok {
							t.Fatalf("missing request group: %v", rec)
						}
						rec = group
					}
					wantTrace, wantSpan := "legacy-trace", "legacy-span"
					if tc.sc.IsValid() {
						wantTrace, wantSpan = tc.sc.TraceID().String(), tc.sc.SpanID().String()
					}
					if rec["trace_id"] != wantTrace || rec["span_id"] != wantSpan {
						t.Errorf("trace attributes = %v, want trace_id %s and span_id %s", rec, wantTrace, wantSpan)
					}
					if strings.Count(buf.String(), `"trace_id":`) != 1 || strings.Count(buf.String(), `"span_id":`) != 1 {
						t.Errorf("duplicate or missing trace keys: %s", buf.String())
					}
				})
			}
		})
	}
}

type logExporter struct {
	mu      sync.Mutex
	records []sdklog.Record
}

func (e *logExporter) Export(_ context.Context, records []sdklog.Record) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, record := range records {
		e.records = append(e.records, record.Clone())
	}
	return nil
}

func (*logExporter) Shutdown(context.Context) error   { return nil }
func (*logExporter) ForceFlush(context.Context) error { return nil }

func TestHandlerCorrelatesJSONAndOTelLogs(t *testing.T) {
	exporter := &logExporter{}
	lp := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewSimpleProcessor(exporter)))
	tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(tracetest.NewInMemoryExporter()))
	defer func() {
		if err := lp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
		if err := tp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	}()
	var buf bytes.Buffer
	logger := slog.New(NewHandler(slog.NewMultiHandler(
		slog.NewJSONHandler(&buf, nil), otelslog.NewHandler("test", otelslog.WithLoggerProvider(lp)),
	))).With("video_id", "video-1", "trace_id", "bound-legacy")
	ctx, span := tp.Tracer("test").Start(context.Background(), "request")
	defer span.End()
	sc := span.SpanContext()
	ctx = With(ctx, slog.String("trace_id", "context-legacy"), slog.String("span_id", "legacy"), slog.String("user_id", "user-1"))
	logger.InfoContext(ctx, "uploaded", slog.String("trace_id", "record-legacy"))
	record := decode(t, &buf)
	if record["trace_id"] != sc.TraceID().String() || record["span_id"] != sc.SpanID().String() {
		t.Fatalf("JSON context differs from span: %v", record)
	}
	if strings.Count(buf.String(), `"trace_id":`) != 1 || strings.Count(buf.String(), `"span_id":`) != 1 {
		t.Fatalf("duplicate trace keys: %s", buf.String())
	}
	if record["user_id"] != "user-1" || record["video_id"] != "video-1" {
		t.Fatalf("missing attributes: %v", record)
	}
	if len(exporter.records) != 1 {
		t.Fatalf("OTel records = %d, want 1", len(exporter.records))
	}
	got := exporter.records[0]
	if got.TraceID() != sc.TraceID() || got.SpanID() != sc.SpanID() {
		t.Fatal("OTel trace fields differ from JSON/span")
	}
	if got.Severity() != otellog.SeverityInfo {
		t.Fatalf("OTel severity = %v, want INFO", got.Severity())
	}
	attrs := map[string]string{}
	got.WalkAttributes(func(a attribute.KeyValue) bool {
		attrs[string(a.Key)] = a.Value.AsString()
		return true
	})
	if attrs["user_id"] != "user-1" || attrs["video_id"] != "video-1" {
		t.Fatalf("OTel lost With attributes: %v", attrs)
	}
	buf.Reset()
	logger.WithGroup("request").InfoContext(ctx, "grouped")
	group := decode(t, &buf)["request"].(map[string]any)
	if group["trace_id"] != sc.TraceID().String() || group["user_id"] != "user-1" {
		t.Fatalf("context attributes lost after WithGroup: %v", group)
	}
}

type logCollector struct {
	collectorlog.UnimplementedLogsServiceServer
	received chan *collectorlog.ExportLogsServiceRequest
}

func (c *logCollector) Export(_ context.Context, req *collectorlog.ExportLogsServiceRequest) (*collectorlog.ExportLogsServiceResponse, error) {
	c.received <- req
	return &collectorlog.ExportLogsServiceResponse{}, nil
}

// childEnv marks the test binary run by TestLoggerCreatedBeforeSetupUsesGlobalProvider.
const childEnv = "SVP_LOGX_TEST_CHILD"

// The OTel log bridge delegates to the first global provider installed after it, once per
// process: a second run in the same process would keep the provider the first one shut down. The
// test runs in a child process of its own, so each run of the parent starts from fresh globals.
func TestLoggerCreatedBeforeSetupUsesGlobalProvider(t *testing.T) {
	if os.Getenv(childEnv) == "" {
		const name = "TestLoggerCreatedBeforeSetupUsesGlobalProvider"
		cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^"+name+"$", "-test.count=1", "-test.v") //nolint:gosec // the test binary itself
		cmd.Env = append(os.Environ(), childEnv+"=1")
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), "--- PASS: "+name) {
			t.Fatalf("child test: %v\n%s", err, out)
		}
		return
	}
	for _, name := range []string{"OTEL_SDK_DISABLED", "PYROSCOPE_SERVER_ADDRESS", "OTEL_TRACES_SAMPLER",
		"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"} {
		t.Setenv(name, "")
	}
	lc := net.ListenConfig{}
	listener, err := lc.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	collector := &logCollector{received: make(chan *collectorlog.ExportLogsServiceRequest, 10)}
	collectorlog.RegisterLogsServiceServer(server, collector)
	go func() { _ = server.Serve(listener) }()
	defer server.Stop()
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://"+listener.Addr().String())
	t.Setenv("OTEL_EXPORTER_OTLP_INSECURE", "true")
	tp, mp, lp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetLoggerProvider()
	prop, eh := otel.GetTextMapPropagator(), otel.GetErrorHandler()
	defer func() {
		otel.SetTracerProvider(tp)
		otel.SetMeterProvider(mp)
		otel.SetLoggerProvider(lp)
		otel.SetTextMapPropagator(prop)
		otel.SetErrorHandler(eh)
	}()
	var buf bytes.Buffer
	logger := newLogger(&buf, "late-provider")
	shutdown, err := telemetry.Setup(context.Background(), "late-provider")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = shutdown(context.Background()) }()
	ctx, span := otel.Tracer("test").Start(context.Background(), "request")
	sc := trace.SpanContextFromContext(ctx)
	logger.InfoContext(With(ctx, slog.String("user_id", "user-1")), "after setup")
	span.End()
	// Flush logs while other signal services remain unimplemented on the fake collector.
	if err := otel.GetLoggerProvider().(*sdklog.LoggerProvider).ForceFlush(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case request := <-collector.received:
		logs := request.ResourceLogs[0]
		foundService := false
		for _, a := range logs.Resource.Attributes {
			if a.Key == "service.name" && a.Value.GetStringValue() == "late-provider" {
				foundService = true
			}
		}
		if !foundService {
			t.Fatal("OTLP log resource lost service.name")
		}
		r := logs.ScopeLogs[0].LogRecords[0]
		traceID, spanID := sc.TraceID(), sc.SpanID()
		if !bytes.Equal(r.TraceId, traceID[:]) || !bytes.Equal(r.SpanId, spanID[:]) {
			t.Fatal("logger created before Setup lost trace correlation")
		}
		if decode(t, &buf)["trace_id"] != sc.TraceID().String() {
			t.Fatal("stdout trace differs from OTLP")
		}
	case <-time.After(time.Second):
		t.Fatal("logger created before Setup did not export")
	}
}

func TestWithDoesNotChangeParentContext(t *testing.T) {
	var buf bytes.Buffer
	logger := newLogger(&buf, "svc")

	parent := With(context.Background(), slog.String("user_id", "a"))
	_ = With(parent, slog.String("video_id", "v"))
	logger.InfoContext(parent, "parent")

	rec := decode(t, &buf)
	if _, ok := rec["video_id"]; ok {
		t.Errorf("child attr leaked into parent context: %v", rec)
	}
	if rec["user_id"] != "a" {
		t.Errorf("user_id = %v, want a", rec["user_id"])
	}
}
