package objstore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"
)

// TestCallsHaveSpans checks each call sent to the storage gets a client span in the caller's
// trace, whose context goes out in the traceparent header, and that signing a form gets none.
func TestCallsHaveSpans(t *testing.T) {
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		otel.SetTracerProvider(noop.NewTracerProvider())
		otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator())
		_ = tp.Shutdown(context.Background())
	})

	var mu sync.Mutex
	var traceparents []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		traceparents = append(traceparents, r.Header.Get("traceparent"))
		mu.Unlock()
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", "42")
			w.Header().Set("Content-Type", "video/mp4")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	s := newTestStore(t, testConfig(srv.URL))

	ctx, parent := tp.Tracer("test").Start(t.Context(), "request")
	if _, err := s.PresignPost(ctx, "uploads/v1", 100, "video/mp4", time.Minute); err != nil {
		t.Fatalf("PresignPost() error = %v", err)
	}
	if _, err := s.Head(ctx, "uploads/v1"); err != nil {
		t.Fatalf("Head() error = %v", err)
	}
	if err := s.Delete(ctx, "media/v1/index.m3u8"); err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	parent.End()

	var names []string
	for _, span := range sr.Ended() {
		if span.Name() == "request" {
			continue
		}
		names = append(names, span.Name())
		if span.SpanKind() != trace.SpanKindClient || span.Parent().SpanID() != parent.SpanContext().SpanID() {
			t.Errorf("span %s: kind %v parent %s, want a client span child of the request", span.Name(), span.SpanKind(), span.Parent().SpanID())
		}
	}
	if got := strings.Join(names, ","); got != "S3.HeadObject,S3.DeleteObject" {
		t.Errorf("spans = %s, want S3.HeadObject,S3.DeleteObject (none for PresignPost)", got)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(traceparents) != 2 {
		t.Fatalf("server got %d requests, want 2", len(traceparents))
	}
	for _, tp := range traceparents {
		if !strings.Contains(tp, parent.SpanContext().TraceID().String()) {
			t.Errorf("traceparent header %q, want the request trace %s", tp, parent.SpanContext().TraceID())
		}
	}
}
