package logx

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"testing"
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
	ctx = With(ctx, slog.String("user_id", "0192f0c4-0000-7000-8000-000000000001"))
	logger.InfoContext(ctx, "rpc", slog.String("method", "/svp.user.v1.UserService/Login"))

	rec := decode(t, &buf)
	want := map[string]string{
		"msg":      "rpc",
		"service":  "user-service",
		"method":   "/svp.user.v1.UserService/Login",
		"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
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
	if rec["service"] != "gateway" {
		t.Errorf("service = %v, want gateway", rec["service"])
	}
}

func TestWithDoesNotChangeParentContext(t *testing.T) {
	var buf bytes.Buffer
	logger := newLogger(&buf, "svc")

	parent := With(context.Background(), slog.String("trace_id", "a"))
	_ = With(parent, slog.String("user_id", "u"))
	logger.InfoContext(parent, "parent")

	rec := decode(t, &buf)
	if _, ok := rec["user_id"]; ok {
		t.Errorf("child attr leaked into parent context: %v", rec)
	}
	if rec["trace_id"] != "a" {
		t.Errorf("trace_id = %v, want a", rec["trace_id"])
	}
}
