package redisx_test

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace/noop"

	"github.com/anhnvcoder/short-video-platform/internal/redistest"
	"github.com/anhnvcoder/short-video-platform/internal/redisx"
)

// TestSpansOmitKeysAndArgs runs against the local Redis: a script call (EVALSHA, then EVAL on
// NOSCRIPT) like the rate limiter's, plain commands and a pipeline, all with a key and arguments
// holding an email, leave spans named after the command that hold neither.
func TestSpansOmitKeysAndArgs(t *testing.T) {
	const secret = "probe-secret@example.com"
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		otel.SetTracerProvider(noop.NewTracerProvider())
		_ = tp.Shutdown(context.Background())
	})

	// redistest checks the URL names the test database and deletes the keys under prefix.
	_, prefix := redistest.New(t)
	c, err := redisx.New(os.Getenv(redistest.EnvURL))
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	ctx, parent := tp.Tracer("test").Start(t.Context(), "request")
	key := prefix + "rl:" + secret
	// Under -race with every package running at once, a call can miss the 50 ms budget of redisx;
	// a span is started before the command is sent, so only its content is checked here.
	script := redis.NewScript(`return redis.call("INCRBY", KEYS[1], ARGV[1])`)
	if err := script.Run(ctx, c, []string{key}, 1).Err(); err != nil {
		t.Logf("script: %v", err)
	}
	if err := c.Set(ctx, key+":set", secret, time.Minute).Err(); err != nil {
		t.Logf("SET: %v", err)
	}
	if _, err := c.Pipelined(ctx, func(p redis.Pipeliner) error {
		p.Get(ctx, key+":set")
		p.Expire(ctx, key, time.Minute)
		return nil
	}); err != nil {
		t.Logf("pipeline: %v", err)
	}
	parent.End()

	names := map[string]bool{}
	for _, s := range sr.Ended() {
		if s.Name() == "request" {
			continue
		}
		names[s.Name()] = true
		// go-redis dials new pool connections outside the command's context.
		if s.Name() != "redis.dial" && s.SpanContext().TraceID() != parent.SpanContext().TraceID() {
			t.Errorf("span %q is in trace %s, want the request trace %s", s.Name(), s.SpanContext().TraceID(), parent.SpanContext().TraceID())
		}
		dump, err := json.Marshal(struct {
			Name   string
			Attrs  any
			Events any
			Status any
		}{s.Name(), s.Attributes(), s.Events(), s.Status()})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(dump), "probe-secret") || strings.Contains(string(dump), prefix) {
			t.Errorf("span %s holds a key or an argument: %s", s.Name(), dump)
		}
		for _, a := range s.Attributes() {
			if a.Key == "db.statement" || a.Key == "db.query.text" {
				t.Errorf("span %s has %s = %q", s.Name(), a.Key, a.Value.String())
			}
		}
	}
	for _, want := range []string{"evalsha", "set", "redis.pipeline get expire"} {
		if !names[want] {
			t.Errorf("no span %q among %v", want, names)
		}
	}
}
