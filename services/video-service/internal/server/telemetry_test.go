package server

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// testTelemetry installs, until the test ends, a tracer provider sampling and recording every
// span, a meter provider read by hand, and W3C TraceContext propagation as the global ones, as
// telemetry.Setup does in serve. Servers and sweepers report to the providers installed when they
// are created, so create them after this call.
func testTelemetry(t *testing.T) (*tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	t.Helper()
	prevTrace, prevMeter, prevProp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetTextMapPropagator()
	recorder := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder), sdktrace.WithSampler(sdktrace.AlwaysSample()))
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		otel.SetTracerProvider(prevTrace)
		otel.SetMeterProvider(prevMeter)
		otel.SetTextMapPropagator(prevProp)
		if err := tp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
		if err := mp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	return recorder, reader
}

// traceparentOf returns the traceparent header that carries span.
func traceparentOf(span trace.Span) string {
	return traceparentOfContext(span.SpanContext())
}

func traceparentOfContext(sc trace.SpanContext) string {
	carrier := propagation.MapCarrier{}
	propagation.TraceContext{}.Inject(trace.ContextWithSpanContext(context.Background(), sc), carrier)
	return carrier.Get("traceparent")
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

// readySamples returns the svp.video.ready.duration points by outcome.
func readySamples(t *testing.T, reader *sdkmetric.ManualReader) map[string]metricdata.HistogramDataPoint[float64] {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	points := map[string]metricdata.HistogramDataPoint[float64]{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.video.ready.duration" {
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

// loopLastSuccess returns the svp.loop.last_success value of loop, and whether it is reported.
func loopLastSuccess(t *testing.T, reader *sdkmetric.ManualReader, loop string) (int64, bool) {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.loop.last_success" {
				continue
			}
			for _, p := range m.Data.(metricdata.Gauge[int64]).DataPoints {
				if v, _ := p.Attributes.Value(attribute.Key("loop")); v.AsString() == loop {
					return p.Value, true
				}
			}
		}
	}
	return 0, false
}

// hangingRollback is a pgx tracer standing for a Postgres that never answers ROLLBACK: the
// statement waits for its context to end. A context without a deadline is given up on after
// unboundedAfter, and counted, so a missing bound fails the test instead of hanging it.
type hangingRollback struct {
	rollbacks atomic.Int32
	unbounded atomic.Int32
}

const unboundedAfter = 10 * time.Second

func (h *hangingRollback) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if !strings.EqualFold(strings.TrimSpace(data.SQL), "rollback") {
		return ctx
	}
	h.rollbacks.Add(1)
	if _, ok := ctx.Deadline(); !ok {
		h.unbounded.Add(1)
	}
	select {
	case <-ctx.Done():
	case <-time.After(unboundedAfter):
	}
	return ctx
}

func (*hangingRollback) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// withHangingRollback returns a pool to the database of pool whose ROLLBACK statements hang.
func withHangingRollback(t *testing.T, pool *pgxpool.Pool) (*pgxpool.Pool, *hangingRollback) {
	t.Helper()
	h := &hangingRollback{}
	cfg := pool.Config()
	cfg.ConnConfig.Tracer = h
	p, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p, h
}
