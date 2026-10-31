package worker

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
)

// spans records every span of the package's tests. Tests run in parallel, so each one looks only
// at the spans of its own trace.
var spans = tracetest.NewSpanRecorder()

// TestMain installs, as telemetry.Setup does in serve, a tracer provider sampling every span and
// W3C TraceContext propagation, for the whole package.
func TestMain(m *testing.M) {
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(spans), sdktrace.WithSampler(sdktrace.AlwaysSample()))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	code := m.Run()
	_ = tp.Shutdown(context.Background())
	os.Exit(code)
}

// spansOf returns the ended spans of trace id.
func spansOf(id trace.TraceID) []sdktrace.ReadOnlySpan {
	var out []sdktrace.ReadOnlySpan
	for _, s := range spans.Ended() {
		if s.SpanContext().TraceID() == id {
			out = append(out, s)
		}
	}
	return out
}

// traceIDOf returns the trace id of a traceparent header.
func traceIDOf(t *testing.T, traceparent string) trace.TraceID {
	t.Helper()
	ctx := propagation.TraceContext{}.Extract(context.Background(), propagation.MapCarrier{"traceparent": traceparent})
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		t.Fatalf("traceparent %q is not valid", traceparent)
	}
	return sc.TraceID()
}

// The spans of a try are in the trace of the record handled: one per download, a transcode span
// with a child per ffprobe and ffmpeg run, and the upload. They name no path.
func TestHandleTracesEachStep(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "640x360", 2))
	ctx, parent := otel.Tracer("test").Start(t.Context(), "process "+InputTopic)
	err := e.w.Handle(ctx, r, kafkax.Attempt{Number: 1})
	parent.End()
	if err != nil {
		t.Fatal(err)
	}

	byName := map[string][]sdktrace.ReadOnlySpan{}
	for _, s := range spansOf(parent.SpanContext().TraceID()) {
		byName[s.Name()] = append(byName[s.Name()], s)
		for _, a := range s.Attributes() {
			if v := a.Value.String(); strings.Contains(v, e.workDir) || strings.Contains(v, "/") {
				t.Errorf("span %s attribute %s = %q names a path", s.Name(), a.Key, v)
			}
		}
		if strings.Contains(s.Name(), "/") {
			t.Errorf("span name %q holds a path", s.Name())
		}
	}
	for _, name := range []string{"download source", "transcode", "upload output"} {
		got := byName[name]
		if len(got) != 1 || got[0].Parent().SpanID() != parent.SpanContext().SpanID() {
			t.Errorf("%q spans = %d, want one child of the record's span", name, len(got))
			continue
		}
		if attrs := got[0].Attributes(); !slices.Equal(attrs, []attribute.KeyValue{attribute.String("video_id", id)}) {
			t.Errorf("%q attributes = %v, want only video_id", name, attrs)
		}
	}
	if transcodeSpans := byName["transcode"]; len(transcodeSpans) == 1 {
		step := transcodeSpans[0].SpanContext().SpanID()
		for _, tool := range []string{"ffprobe", "ffmpeg"} {
			if len(byName[tool]) == 0 {
				t.Errorf("no %s span", tool)
			}
			for _, s := range byName[tool] {
				if s.Parent().SpanID() != step || len(s.Attributes()) != 0 {
					t.Errorf("%s span: parent %s, attributes %v; want a child of transcode without attributes",
						tool, s.Parent().SpanID(), s.Attributes())
				}
			}
		}
	}
}

// transcodeSamples returns the svp.transcode.duration points by outcome.
func transcodeSamples(t *testing.T, reader *sdkmetric.ManualReader) map[string]metricdata.HistogramDataPoint[float64] {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	points := map[string]metricdata.HistogramDataPoint[float64]{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.transcode.duration" {
				continue
			}
			if m.Unit != "s" {
				t.Errorf("unit = %q, want s", m.Unit)
			}
			for _, p := range m.Data.(metricdata.Histogram[float64]).DataPoints {
				outcome, _ := p.Attributes.Value(attribute.Key("outcome"))
				if p.Attributes.Len() != 1 {
					t.Errorf("attributes = %v, want only outcome", p.Attributes)
				}
				points[outcome.AsString()] = p
			}
		}
	}
	return points
}

// svp.transcode.duration counts a try that transcoded, as ready, and one whose file failed the
// probe, as failed; a try that never reached transcoding counts nothing. Not parallel: it swaps
// the global meter provider before the parallel tests start.
func TestHandleRecordsTranscodeDuration(t *testing.T) {
	requireFFmpeg(t)
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	e := newEnv(t)

	_, r := e.withSource(t, clip(t, "640x360", 2))
	e.handle(t, r)
	_, bad := e.withSource(t, []byte("hello, this is not a video\n"))
	e.handle(t, bad)
	e.handle(t, uploaded(t, ids.New(), 1000, nil)) // source missing

	points := transcodeSamples(t, reader)
	if len(points) != 2 || points["ready"].Count != 1 || points["failed"].Count != 1 {
		t.Fatalf("samples = %v, want one ready and one failed", points)
	}
	if p := points["ready"]; p.Sum <= 0 || !slices.Equal(p.Bounds, transcodeBuckets) {
		t.Errorf("ready sample = %.3fs with bounds %v, want positive with %v", p.Sum, p.Bounds, transcodeBuckets)
	}
}
