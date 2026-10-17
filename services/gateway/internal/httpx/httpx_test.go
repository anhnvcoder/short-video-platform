package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
)

// captureLog points slog.Default at a logx JSON handler writing to the returned buffer until
// the test ends. Tests using it must not run in parallel.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil))))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

// logRecords returns the decoded log lines whose msg is msg.
func logRecords(t *testing.T, buf *bytes.Buffer, msg string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for line := range bytes.Lines(buf.Bytes()) {
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

// decodeProblem checks the problem+json content type and returns the body.
func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) problem {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("Content-Type = %q, want application/problem+json", ct)
	}
	var p problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("problem body %q: %v", rec.Body.String(), err)
	}
	if p.Type != "about:blank" {
		t.Errorf("type = %q, want about:blank", p.Type)
	}
	if p.Status != rec.Code {
		t.Errorf("status field = %d, response status = %d", p.Status, rec.Code)
	}
	return p
}

func TestNewServerLimits(t *testing.T) {
	h := http.NewServeMux()
	s := NewServer("127.0.0.1:8080", h)
	if s.Addr != "127.0.0.1:8080" || s.Handler != h {
		t.Errorf("Addr = %q, Handler = %v; want the given ones", s.Addr, s.Handler)
	}
	durations := []struct {
		name      string
		got, want time.Duration
	}{
		{"ReadHeaderTimeout", s.ReadHeaderTimeout, 5 * time.Second},
		{"ReadTimeout", s.ReadTimeout, 10 * time.Second},
		{"WriteTimeout", s.WriteTimeout, 15 * time.Second},
		{"IdleTimeout", s.IdleTimeout, 60 * time.Second},
	}
	for _, d := range durations {
		if d.got != d.want {
			t.Errorf("%s = %v, want %v", d.name, d.got, d.want)
		}
	}
	if s.MaxHeaderBytes != 16*1024 {
		t.Errorf("MaxHeaderBytes = %d, want %d", s.MaxHeaderBytes, 16*1024)
	}
}

func TestNewServerRejectsDefaultHandlers(t *testing.T) {
	for _, h := range []http.Handler{nil, http.DefaultServeMux} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("NewServer(%v) did not panic", h)
				}
			}()
			NewServer("127.0.0.1:8080", h)
		}()
	}
}

func TestOutgoingContextReplacesExistingMetadata(t *testing.T) {
	ctx := metadata.NewOutgoingContext(context.Background(), metadata.Pairs(
		callerid.MetadataKey, "01928c6e-7b3a-7cde-8f01-000000000000",
		"x-foo", "bar",
		"traceparent", clientTraceparent,
	))
	// The request's span is sent by the stats handler, not by OutgoingContext.
	ctx, span := testTracerProvider.Tracer("test").Start(ctx, "request")
	defer span.End()

	md, _ := metadata.FromOutgoingContext(OutgoingContext(ctx))
	if len(md) != 0 {
		t.Errorf("unauthenticated metadata = %v, want none", md)
	}

	const userID = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	md, _ = metadata.FromOutgoingContext(OutgoingContext(context.WithValue(ctx, userIDKey, userID)))
	if got := md.Get(callerid.MetadataKey); len(got) != 1 || got[0] != userID {
		t.Errorf("x-user-id = %v, want [%s]", got, userID)
	}
	if len(md) != 1 {
		t.Errorf("authenticated metadata = %v, want only x-user-id", md)
	}
}
